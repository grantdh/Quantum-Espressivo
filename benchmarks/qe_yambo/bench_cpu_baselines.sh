#!/usr/bin/env bash
# bench_cpu_baselines.sh — targeted AB_MODE=cpu baselines for the paper.
#
# The NP × OMP sweeps established winning configs:
#   si64_500b:  NP=1 OMP=1 (150s), NP=2 OMP=2 (75s)  — apple-bottom engaged
#   si216:      NP=1 OMP=1 (1240s), NP=2 OMP=2 (506s) — apple-bottom engaged
#
# To claim "apple-bottom speedup" in the paper we need matching AB_MODE=cpu
# points at the same (NP, OMP) — same parallelism, apple-bottom dispatcher
# forced to CPU path instead of GPU. Speedup = cpu_wall / auto_wall.
#
# Four points total, ~70 min on M2 Max:
#   (si64_500b, NP=1 OMP=1)  ~10 min
#   (si64_500b, NP=2 OMP=2)  ~5 min
#   (si216,    NP=1 OMP=1)   ~35 min
#   (si216,    NP=2 OMP=2)   ~15 min
#
# Output: results/paper_speedup/paper_speedup.csv with columns:
#   system,np,omp,mode,wall_s,cpu_calls,gpu_calls,total_E_Ry,status
#
# Usage:
#   ./bench_cpu_baselines.sh [--timeout SECONDS]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/config.sh"

TIMEOUT="${QE_TIMEOUT:-7200}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout) TIMEOUT="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

OUT_ROOT="${HERE}/results/paper_speedup"
mkdir -p "${OUT_ROOT}"
CSV="${OUT_ROOT}/paper_speedup.csv"
if [[ ! -f "${CSV}" ]]; then
    echo "system,np,omp,mode,wall_s,cpu_calls,gpu_calls,total_E_Ry,status" > "${CSV}"
fi

# Sanity
if ! otool -L "${PW_BIN}" 2>/dev/null | grep -qE "applebottom|libab"; then
    echo "${C_RED}ERROR${C_RST}: pw.x not linked against libapplebottom.dylib"
    exit 1
fi

# --- run one point -------------------------------------------------------
run_point() {
    local system="$1" np="$2" omp="$3" mode="$4"
    local input="${BENCH_INPUT_DIR}/${system}/scf.in"
    if [[ ! -f "${input}" ]]; then
        echo "${C_RED}ERROR${C_RST}: no input at ${input}"
        return 1
    fi
    local label="${system}_np${np}_omp${omp}_${mode}"
    local out="${OUT_ROOT}/${label}"
    rm -rf "${out}"; mkdir -p "${out}"
    cp "${input}" "${out}/scf.in"

    echo "${C_BLU}=== [$(ts)] ${system} NP=${np} OMP=${omp} AB_MODE=${mode} ===${C_RST}"
    local start end wall rc=0
    start=$(date +%s)
    local TO; TO="$(command -v gtimeout || command -v timeout || true)"
    (
        cd "${out}"
        ulimit -s unlimited 2>/dev/null || true
        env -i HOME="$HOME" PATH="$PATH" \
            OMP_NUM_THREADS="${omp}" \
            AB_MODE="${mode}" \
            AB_CROSSOVER_FLOPS=100000000 \
            AB_PROFILE_FILE="${out}/gemm_profile.txt" \
            ${TO:+${TO} ${TIMEOUT}} \
            mpirun -np "${np}" "${PW_BIN}" -inp scf.in > scf.out 2>scf.err
    ) || rc=$?
    end=$(date +%s); wall=$((end - start))

    local status="OK" etot="NA"
    if [[ ${rc} -ne 0 ]]; then
        if [[ ${rc} -eq 124 ]]; then status="TIMEOUT"; else status="FAIL(rc=${rc})"; fi
    fi
    etot="$(grep '^! *total energy' "${out}/scf.out" 2>/dev/null | tail -1 | awk '{print $(NF-1)}')"
    [[ -z "${etot}" ]] && etot="NA"

    local cc=0 gc=0
    if [[ -f "${out}/gemm_profile.txt" ]]; then
        awk 'NR>1 { g[$6]++ }
             END { for (k in g) printf "%s calls=%d\n", (k==1?"gpu":"cpu"), g[k] }' \
            "${out}/gemm_profile.txt" > "${out}/gemm_summary.txt" || true
        cc=$(grep '^cpu calls' "${out}/gemm_summary.txt" 2>/dev/null | awk '{print $2}' | sed 's/calls=//' || echo 0)
        gc=$(grep '^gpu calls' "${out}/gemm_summary.txt" 2>/dev/null | awk '{print $2}' | sed 's/calls=//' || echo 0)
    fi

    printf "    wall=%5ds  cpu_calls=%-5s  gpu_calls=%-5s  E=%-16s  [%s]\n" \
        "${wall}" "${cc:-0}" "${gc:-0}" "${etot}" "${status}"
    echo "${system},${np},${omp},${mode},${wall},${cc:-0},${gc:-0},${etot},${status}" >> "${CSV}"
}

echo "[$(ts)] Paper baseline runs (AB_MODE=cpu at winning configs)"
echo "[$(ts)] CSV: ${CSV}"
echo ""

# Four cpu-mode points (matches the winning auto configs)
run_point si64_500b 1 1 cpu
run_point si64_500b 2 2 cpu
run_point si216     1 1 cpu
run_point si216     2 2 cpu

# --- speedup summary -----------------------------------------------------
echo ""
echo "${C_BLD}=== Paper speedup table ===${C_RST}"
printf "  %-12s %-8s %-8s %-8s %-8s\n" "system" "config" "cpu_s" "auto_s" "speedup"

# Look up auto-mode wall times from prior NP×OMP sweep CSVs
lookup_auto() {
    local system="$1" np="$2" omp="$3"
    local csv="${HERE}/results/qe_${system}_nposmp/nposmp.csv"
    [[ -f "${csv}" ]] || { echo "NA"; return; }
    awk -F, -v n="${np}" -v o="${omp}" \
        'NR>1 && $1==n && $2==o {print $3; exit}' "${csv}"
}

for spec in "si64_500b,1,1" "si64_500b,2,2" "si216,1,1" "si216,2,2"; do
    IFS=, read -r sys np omp <<< "${spec}"
    cpu_wall=$(awk -F, -v s="${sys}" -v n="${np}" -v o="${omp}" \
        'NR>1 && $1==s && $2==n && $3==o && $4=="cpu" {print $5; exit}' "${CSV}")
    auto_wall=$(lookup_auto "${sys}" "${np}" "${omp}")
    if [[ -n "${cpu_wall}" ]] && [[ -n "${auto_wall}" ]] && [[ "${auto_wall}" != "NA" ]]; then
        speedup=$(python3 -c "print(f'{${cpu_wall}/${auto_wall}:.2f}x')" 2>/dev/null || echo "NA")
    else
        speedup="NA"
    fi
    printf "  %-12s NP=%d,OMP=%d  %-8s %-8s %-8s\n" \
        "${sys}" "${np}" "${omp}" "${cpu_wall:-NA}" "${auto_wall:-NA}" "${speedup}"
done

echo ""
echo "CSV: ${CSV}"
