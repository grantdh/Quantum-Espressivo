#!/bin/bash
# Run pw.x configurations alternately and repeatedly, on AC power only; one results.csv row per run.
# After apple-bottom's benchmarks/qe/run_campaign.sh.
#
# Usage: PSEUDO_DIR=dir INPUTS=dir split/run.sh <plan> <out-dir>
# Plan lines (# starts a comment; no value may contain a space):
#   config <name> <pw.x> [NP=n] [THREADS=t] [VAR=value ...]
#       a configuration: the binary, optionally its own ranks and threads, and its environment
#   run <label> <input-stem> <np> <threads> <rounds> <config,config,...> [pw.x args ...] [VAR=value ...]
#       rounds 1..<rounds> (or <first>-<last>) over the configurations, with <np> ranks and
#       <threads> threads unless the configuration sets them. An odd round r runs the list rotated
#       by r-1, an even one the list rotated by r and reversed: the first configuration changes
#       from round to round, and no configuration always follows the same one. The input is
#       INPUTS/<stem>.in with OUTDIR and PSEUDO_DIR filled in.
# Every rank gets OMP_NUM_THREADS=1, VECLIB_MAXIMUM_THREADS and OPENBLAS_NUM_THREADS = <threads> and
# QE_FFTW_THREADS=1, then the configuration's variables, then the run line's. A value @file is
# replaced by that file's first line when the run starts (e.g. a share table from calibrate.py).
# A run goes to <out>/runs/<label>/<stem>/<config>_r<round>/ (input.in, out.txt, err.txt, meta.txt,
# and any trace files the run writes there) and a row of <out>/results.csv. It starts only when
# the Mac draws from AC power (pmset); otherwise the script stops with status 75. A run that failed
# or did not end on AC power is moved aside to <dir>.bad<n>, and the script exits with status 4
# after the plan. A run whose meta.txt says "rc=0" and "power_end=AC Power" is done and skipped,
# so running the script again resumes and redoes what failed.
# Run it inside a machine lock that keeps other jobs off the machine.
# IDLE_S (default 15): seconds of idle before each run.
set -u
PLAN="$1"
OUT="$(mkdir -p "$2" && cd "$2" && pwd)"
: "${PSEUDO_DIR:?}" "${INPUTS:?}"
IDLE_S="${IDLE_S:-15}"
CSV="$OUT/results.csv"
TIMERS="cegterg h_psi s_psi calbec add_vuspsi vloc_psi fftw sum_band PAW_pot"
[ -f "$CSV" ] || echo "label,input,np,threads,config,rep,start,end,rc,power_start,power_end,load1_start,load1_end,energy_Ry,scf_iters,wall_s,cpu_s,$(echo $TIMERS | sed -E 's/([^ ]+)/\1_s/g; s/ /,/g'),binary,run_dir,env" > "$CSV"

power() { pmset -g batt | head -1 | sed -E "s/.*'(.*)'.*/\1/"; }
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
snap() {  # <start|end>: the machine's state, for meta.txt
  echo "$1=$(date '+%F %T %Z')"; echo "power_$1=$(power)"; echo "load_$1=$(sysctl -n vm.loadavg)"
  echo "batt_$1=$(pmset -g batt | tail -n +2 | head -1 | sed -E 's/^ *//')"
  echo "therm_$1=$(pmset -g therm | tr -s "\n" " ")"
}
to_s() {  # QE time string (1h02m, 10m15.54s, 95.65s) -> seconds
  echo "$1" | awk '{ t = 0; s = $0
    while (match(s, /[0-9.]+[hms]/)) { v = substr(s, RSTART, RLENGTH - 1); u = substr(s, RSTART + RLENGTH - 1, 1)
      t += v * (u == "h" ? 3600 : u == "m" ? 60 : 1); s = substr(s, RSTART + RLENGTH) }
    if ($0 != "") printf "%.2f", t }'
}
timer() {  # <out> <name>: WALL seconds of that QE timer (its first line)
  local line; line=$(grep -E "^ +$2 +:" "$1" | head -1)
  [ -n "$line" ] && to_s "$(echo "$line" | sed -E 's/.*CPU +([0-9hms.]+) WALL.*/\1/')"
}
config() {  # <name>: "<binary> [VAR=value ...]" from the plan's config line
  awk -v n="$1" '$1 == "config" && $2 == n { $1 = ""; $2 = ""; sub(/^ +/, ""); print; exit }' "$PLAN"
}
movebad() { local k=1; while [ -e "$1.bad$k" ]; do k=$((k + 1)); done; mv "$1" "$1.bad$k"; echo "$1.bad$k"; }

failed=0
while read -r kind label stem np threads rounds configs args || [ -n "${kind:-}" ]; do
  [ "${kind:-}" = run ] || continue
  IFS=, read -r -a C <<< "$configs"
  case "$rounds" in *-*) r0="${rounds%-*}"; r1="${rounds#*-}";; *) r0=1; r1="$rounds";; esac
  nc=${#C[@]}
  for ((r = r0; r <= r1; r++)); do
    for ((i = 0; i < nc; i++)); do
      cfg="${C[$(( r % 2 ? (i + r - 1) % nc : (nc - 1 - i + r) % nc ))]}"
      def="$(config "$cfg")"
      [ -n "$def" ] || { echo "no config $cfg in $PLAN" >&2; exit 2; }
      read -r bin cenv <<< "$def"
      d="$OUT/runs/$label/$stem/${cfg}_r$r"
      if [ -f "$d/meta.txt" ] && grep -q '^rc=0$' "$d/meta.txt" && grep -q '^power_end=AC Power$' "$d/meta.txt"; then continue; fi
      [ -e "$d" ] && movebad "$d" > /dev/null
      n="$np"; th="$threads"
      for t in ${cenv:-}; do case "$t" in NP=*) n="${t#NP=}";; THREADS=*) th="${t#THREADS=}";; esac; done
      xenv=(-x OMP_NUM_THREADS=1 -x VECLIB_MAXIMUM_THREADS="$th" -x OPENBLAS_NUM_THREADS="$th" -x QE_FFTW_THREADS=1)
      pwa=()
      for t in ${cenv:-} ${args:-}; do
        case "$t" in
          NP=*|THREADS=*) ;;
          *=@*) f="${t#*=@}"; [ -s "$f" ] || { echo "missing or empty $f (for $t)" >&2; exit 2; }
                xenv+=(-x "${t%%=@*}=$(head -1 "$f")");;
          *=*) xenv+=(-x "$t");;
          *) pwa+=("$t");;
        esac
      done
      [ "$(power)" = "AC Power" ] || { echo "== $(date '+%F %T') on battery: stopping before $label $stem $cfg r$r"; exit 75; }
      sleep "$IDLE_S"
      mkdir -p "$d/tmp"
      sed -e "s#OUTDIR#$d/tmp#" -e "s#PSEUDO_DIR#$PSEUDO_DIR#" "$INPUTS/$stem.in" > "$d/input.in"
      p0=$(power); l0=$(load1); t0=$(date +%s)
      { snap start; echo "np=$n threads=$th"; echo "binary=$bin"; echo "args=${pwa[*]-}"; echo "env=${xenv[*]}"; } > "$d/meta.txt"
      echo "== $(date '+%T') $label $stem np=$n threads=$th $cfg r$r (power=$p0 load=$l0)"
      # Values on mpirun's command line: a SIP-protected launcher in front would strip DYLD_* variables.
      ( cd "$d" && mpirun -np "$n" "${xenv[@]}" -x DYLD_PRINT_LIBRARIES=1 "$bin" ${pwa[@]+"${pwa[@]}"} \
          -in input.in < /dev/null > out.txt 2> err.txt )
      rc=$?; t1=$(date +%s); p1=$(power); l1=$(load1)
      rm -rf "$d/tmp"
      { snap end; echo "rc=$rc"; } >> "$d/meta.txt"
      o="$d/out.txt"
      energy=$(grep -E '^!' "$o" | tail -1 | awk '{print $(NF-1)}')
      iters=$(grep -E 'convergence has been achieved in' "$o" | awk '{print $(NF-1)}')
      pw=$(grep -E 'PWSCF +:' "$o" | tail -1)
      wall=$(to_s "$(echo "$pw" | sed -E 's/.*CPU +(.*) WALL.*/\1/')"); cpu=$(to_s "$(echo "$pw" | sed -E 's/.*: +(.*) CPU.*/\1/')")
      tms=""; for t in $TIMERS; do tms="$tms,$(timer "$o" "$t")"; done
      dd="$d"
      if [ "$rc" != 0 ] || [ "$p1" != "AC Power" ] || [ -z "$energy" ]; then dd=$(movebad "$d"); failed=1; fi
      echo "$label,$stem,$n,$th,$cfg,$r,$t0,$t1,$rc,$p0,$p1,$l0,$l1,$energy,$iters,$wall,$cpu$tms,$bin,${dd#$OUT/},\"${xenv[*]} ${pwa[*]-}\"" >> "$CSV"
      echo "   rc=$rc E=$energy iters=$iters wall=${wall}s power=$p1"
      [ "$dd" = "$d" ] || echo "   moved to ${dd#$OUT/}"
      [ "$p1" = "AC Power" ] || { echo "== $(date '+%F %T') on battery after the run: stopping"; exit 75; }
    done
  done
done < "$PLAN"
echo "== $(date '+%F %T') plan done: $PLAN$([ $failed = 1 ] && echo ', with failed runs')"
[ $failed = 0 ] || exit 4
