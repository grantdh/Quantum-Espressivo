#!/bin/bash
# The split prototype's measurement from start to end: build, check, calibrate, time, tabulate.
#
# Usage: QE_DIR=... AB_LIB=... AB_INC=... INPUTS=... PSEUDO_DIR=... OUT=... split/campaign.sh [step]
#   QE_DIR AB_LIB AB_INC AB_LIB_FIX  as for build-qe.sh (AB_LIB_FIX optional: pw.x.fix, calibrated
#               and timed as a configuration of its own); INPUTS holds A_si64_500b_k222.in and
#               B_si64_160b_k222.in
#   LOCK_BUILD  prefix for configure and make (a shared machine lock); LOCK_BENCH  prefix for each
#               benchmark block (an exclusive machine lock); both empty by default
#   REPS (3) timing rounds, CAL_ITERS (3) calibration iterations, IDLE_S (15) idle before each run
# A benchmark block waits for AC power, takes LOCK_BENCH once, checks for AC power again inside it,
# samples pmset every 20 s into $OUT/power.log and runs 2-5 pw.x runs. A block that meets battery
# power (status 75) is retried 10 minutes later; a run that fails is redone once.
# Steps (all, the default, runs them in order and skips what is done):
#   build      build-qe.sh: pw.x.cpu and pw.x.split from one QE tree into $OUT/bin (and pw.x.fix)
#   gpu        test_split with AB_MODE=gpu: every split shape against cblas, GPU parts on the GPU
#   calib V L  calibration in QE of variant V (split, fix) at layout L (8x1: 8 ranks x 1 thread,
#              4x2: 4 x 2), one block per iteration: A and B split with the current shares, then
#              calibrate.py, from the starting shares zUN 0.51, zUM 0.50, zRK 0.55. The first block
#              also runs A and B with every call on Accelerate (off, below; once per layout), and its
#              split runs must pass analyze.py's gate against them (energy within 1e-5 Ry, SCF
#              iterations within 2), or the campaign stops before any timing. The table after
#              CAL_ITERS iterations is frozen as $OUT/shares-V-L.txt.
#   time R S L round R of input S at layout L, one block, configurations in run.sh's order for the
#              round; REPS rounds over A and B at both layouts:
#                8x1 (label t8): cpu8 split8 fix8 off8 gpu8    4x2 (label t4): cpu8 cpu4 split4 fix4
#                cpu    pw.x.cpu, AB_MODE=cpu: every GEMM on Accelerate (the release check's cpu mode)
#                split  pw.x.split, QE_SPLIT=1 with its layout's frozen table; fix: pw.x.fix, likewise
#                off    pw.x.split, QE_SPLIT=0: the shim passing every call to Accelerate
#                gpu    pw.x.cpu, AB_MODE=gpu: the library's own GPU routing
#              The 4x2 blocks run cpu8 too, so that each block holds the best CPU layout.
#   tables     analyze.py: $OUT/tables-time.md and $OUT/tables-calib-L.md
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${QE_DIR:?}" "${AB_LIB:?}" "${AB_INC:?}" "${INPUTS:?}" "${PSEUDO_DIR:?}" "${OUT:?}"
REPS="${REPS:-3}"; CAL_ITERS="${CAL_ITERS:-3}"
export PSEUDO_DIR INPUTS IDLE_S="${IDLE_S:-15}"
mkdir -p "$OUT/state"
OUT="$(cd "$OUT" && pwd)"
BIN="$OUT/bin"
A=A_si64_500b_k222; B=B_si64_160b_k222
LAYOUTS="8x1 4x2"
VARIANTS="split${AB_LIB_FIX:+ fix}"
SHARES0="zUN=0.51 zUM=0.50 zRK=0.55"
SPLIT_ENV="QE_SPLIT=1 AB_MODE=gpu AB_MIN_GPU_DIM=0 AB_REPORT=1 AB_TRACE=trace QE_SPLIT_LOG=split QE_SPLIT_REPORT=1"
OFF_ENV="QE_SPLIT=0 QE_SPLIT_REPORT=1 AB_REPORT=1"
log() { echo "== $(date '+%F %T') $*" | tee -a "$OUT/campaign.log"; }
power() { pmset -g batt | head -1 | sed -E "s/.*'(.*)'.*/\1/"; }

inside() {  # <command...>: in a block, on AC power, with the power sampled every 20 s
  [ "$(power)" = "AC Power" ] || { log "$*: on battery inside the lock"; exit 75; }
  while :; do
    echo "$(date '+%F %T') $(pmset -g batt | head -2 | tr '\n' ' ' | tr -s ' \t' ' ') load $(sysctl -n vm.loadavg)"
    sleep 20
  done >> "$OUT/power.log" &
  local sampler=$! rc
  "$@"; rc=$?
  kill "$sampler" 2>/dev/null
  return "$rc"
}

run_plan() {  # <plan> <dir>: run.sh, and once more if a run failed (status 4)
  "$HERE/run.sh" "$1" "$2"; local rc=$?
  [ "$rc" = 4 ] && { log "$1: a run failed, running the plan once more"; "$HERE/run.sh" "$1" "$2"; rc=$?; }
  return "$rc"
}

step_gpu() {
  { echo "# $AB_LIB"; AB_MODE=gpu AB_MIN_GPU_DIM=0 "$BIN/test_split" && AB_MODE=gpu AB_MIN_GPU_DIM=0 "$BIN/test_split" head &&
    if [ -n "${AB_LIB_FIX:-}" ]; then  # test_split's rpath names AB_LIB; DYLD_LIBRARY_PATH comes first for @rpath
      echo "# $AB_LIB_FIX"; DYLD_LIBRARY_PATH="$AB_LIB_FIX" AB_MODE=gpu AB_MIN_GPU_DIM=0 "$BIN/test_split"; fi
  } > "$OUT/gpu-test.txt" 2>&1
}

step_calib() {  # <variant> <layout>: the next calibration iteration
  local V="$1" L="$2" np="${2%x*}" th="${2#*x}" C="$OUT/calib-$2" i=0 cfgs
  mkdir -p "$C"
  [ -s "$C/$V-shares-0.txt" ] || echo "$SHARES0" > "$C/$V-shares-0.txt"
  while [ -s "$C/$V-shares-$((i + 1)).txt" ]; do i=$((i + 1)); done
  [ "$i" -lt "$CAL_ITERS" ] || return 0
  cfgs="$V-s$i"
  [ "$i" = 0 ] && cfgs="off$np,$cfgs"  # off ran already if another variant was calibrated first
  {
    echo "config off$np $BIN/pw.x.split NP=$np THREADS=$th $OFF_ENV"
    echo "config $V-s$i $BIN/pw.x.$V NP=$np THREADS=$th $SPLIT_ENV QE_SPLIT_F=@$C/$V-shares-$i.txt"
    for s in $A $B; do echo "run cal $s 0 0 1 $cfgs -nk 4"; done
  } > "$C/plan-$V-$i.txt"
  run_plan "$C/plan-$V-$i.txt" "$C" || return $?
  if [ "$i" = 0 ] && ! python3 "$HERE/analyze.py" "$C" --ref off --gate "$V-s0" >> "$OUT/campaign.log" 2>&1; then
    touch "$OUT/state/STOP"; log "physics gate failed: $V at $L (campaign.log)"; return 3
  fi
  python3 "$HERE/calibrate.py" "$C/runs/cal/$A/$V-s${i}_r1" "$C/runs/cal/$B/$V-s${i}_r1" \
    > "$C/$V-shares-$((i + 1)).tmp" 2> "$C/$V-calibrate-$i.txt" || return 1
  mv "$C/$V-shares-$((i + 1)).tmp" "$C/$V-shares-$((i + 1)).txt"
  log "calib $V $L iteration $i: next shares $(cat "$C/$V-shares-$((i + 1)).txt")"
  [ $((i + 1)) -lt "$CAL_ITERS" ] || cp "$C/$V-shares-$CAL_ITERS.txt" "$OUT/shares-$V-$L.txt"
}

step_time() {  # <round> <input> <layout>
  local R="$1" S="$2" L="$3" np="${3%x*}" T="$OUT/time" cfgs l n t rc
  if [ "$L" = 8x1 ]; then cfgs="cpu8"; else cfgs="cpu8,cpu$np"; fi
  for V in $VARIANTS; do cfgs="$cfgs,$V$np"; done
  [ "$L" = 8x1 ] && cfgs="$cfgs,off8,gpu8"
  mkdir -p "$T/plans"
  {
    for l in $LAYOUTS; do
      n="${l%x*}"; t="${l#*x}"
      echo "config cpu$n $BIN/pw.x.cpu NP=$n THREADS=$t AB_MODE=cpu AB_REPORT=1"
      for V in $VARIANTS; do echo "config $V$n $BIN/pw.x.$V NP=$n THREADS=$t $SPLIT_ENV QE_SPLIT_F=@$OUT/shares-$V-$l.txt"; done
    done
    echo "config off8 $BIN/pw.x.split NP=8 THREADS=1 $OFF_ENV"
    echo "config gpu8 $BIN/pw.x.cpu NP=8 THREADS=1 AB_MODE=gpu AB_REPORT=1"
    echo "run t$np $S 0 0 $R-$R $cfgs -nk 4"
  } > "$T/plans/r$R-$S-$L.txt"
  run_plan "$T/plans/r$R-$S-$L.txt" "$T"; rc=$?
  [ "$rc" = 4 ] && { log "time r$R $S $L: a run failed twice; the tables have one run fewer"; rc=0; }
  return "$rc"
}

step_tables() {
  python3 "$HERE/analyze.py" "$OUT/time" --ref cpu --base cpu8 > "$OUT/tables-time.md" || return 1
  for L in $LAYOUTS; do python3 "$HERE/analyze.py" "$OUT/calib-$L" --ref off > "$OUT/tables-calib-$L.md" || return 1; done
}

bench() {  # <step> [args]: one LOCK_BENCH hold, taken on AC power
  local rc
  while :; do
    until [ "$(power)" = "AC Power" ]; do sleep 60; done
    log "waiting for the bench lock: $*"
    ${LOCK_BENCH:-} caffeinate -is "$0" "$@"
    rc=$?
    [ "$rc" = 75 ] && { log "$*: battery power, retrying in 10 minutes"; sleep 600; continue; }
    return "$rc"
  done
}

calib_all() {  # <variant> <layout>: one block per iteration until the table is frozen
  until [ -s "$OUT/shares-$1-$2.txt" ]; do bench calib "$1" "$2" || return $?; done
}

step() {  # <name> <command...>: run once, mark done
  [ -f "$OUT/state/$1.done" ] && return 0
  [ -f "$OUT/state/STOP" ] && { log "stopped earlier (state/STOP); not running $1"; exit 3; }
  local n="$1"; shift
  log "step $n"
  "$@" || { log "step $n failed (rc $?)"; exit 1; }
  touch "$OUT/state/$n.done"; log "step $n done"
}

case "${1:-all}" in
  gpu) inside step_gpu ;;
  calib) inside step_calib "$2" "$3" ;;
  time) inside step_time "$2" "$3" "$4" ;;
  tables) step_tables ;;
  all)
    step build env QE_DIR="$QE_DIR" AB_LIB="$AB_LIB" AB_INC="$AB_INC" AB_LIB_FIX="${AB_LIB_FIX:-}" OUT="$BIN" \
      LOCK_BUILD="${LOCK_BUILD:-}" "$HERE/build-qe.sh"
    step gpu bench gpu
    for V in $VARIANTS; do for L in $LAYOUTS; do step "calib-$V-$L" calib_all "$V" "$L"; done; done
    for ((R = 1; R <= REPS; R++)); do
      for S in $A $B; do for L in $LAYOUTS; do step "time-r$R-$S-$L" bench time "$R" "$S" "$L"; done; done
    done
    step tables step_tables
    log "campaign done: $OUT/tables-time.md" ;;
  *) echo "unknown step $1" >&2; exit 2 ;;
esac
