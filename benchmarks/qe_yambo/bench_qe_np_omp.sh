#!/usr/bin/env bash
# bench_qe_np_omp.sh — 6-point NP × OMP sweep on M2 Max.
#
# Runs QE SCF under AB_MODE=auto at fixed AB_CROSSOVER_FLOPS, varying only
# (NP, OMP). Single trial per point — threshold sweep already established
# ~1% run-to-run noise, which is dwarfed by the 2-4× range expected across
# parallel configs.
#
# M2 Max topology: 8 P-cores + 4 E-cores. Keep NP × OMP ≤ 8 to stay on P-cores.
# NP=8 OMP=1 is the ceiling point; going above spills onto E-cores (~3× slower).
#
# Grid:
#   (1,1)  baseline                               — single-rank, single-thread
#   (1,4)  single GPU context + OMP on CPU calls  — OMP scaling test
#   (2,2)  balanced                               — 2 GPU contexts, moderate OMP
#   (4,1)  paper-realistic pure MPI               — 4 GPU contexts
#   (4,2)  full P-core utilization                — NP × OMP = 8
#   (8,1)  max MPI, GPU context contention        — tests ceiling
#
# Output: results/qe_<sys>_nposmp/np<N>_omp<M>/summary.txt + nposmp.csv
#
# Usage:
#   ./bench_qe_np_omp.sh <system_id>
#       [--threshold AB_CROSSOVER_FLOPS_value]   (default 100000000)
#       [--grid "1,1 1,4 2,2 4,1 4,2 8,1"]
#       [--timeout SECONDS]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/config.sh"

SYSTEM="${1:-}"
[[ -n "${SYSTEM}" ]] || { echo "Usage: $0 <system_id> [--threshold N] [--grid \"NP,OMP ...\"] [--timeout S]"; exit 1; }
shift || true

THRESHOLD="100000000"
GRID="1,1 1,4 2,2 4,1 4,2 8,1"
TIMEOUT="${QE_TIMEOUT}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --grid)      GRID="$2";      shift 2 ;;
        --timeout)   TIMEOUT="$2";   shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

OUT_ROOT="${HERE}/results/qe_${SYSTEM}_nposmp"
mkdir -p "${OUT_ROOT}"
CSV="${OUT_ROOT}/nposmp.csv"
echo "np,omp,wall_s,cpu_calls,gpu_calls,total_E_Ry,status" > "${CSV}"

# --- locate input --------------------------------------------------------
INPUT_FILE=""
if [[ -f "${BENCH_INPUT_DIR}/${SYSTEM}/scf.in" ]]; then
    INPUT_FILE="${BENCH_INPUT_DIR}/${SYSTEM}/scf.in"
elif INPUT_FILE="$(qe_input_file "${SYSTEM}")"; then
    :
else
    echo "${C_RED}ERROR${C_RST}: no input for '${SYSTEM}'."
    exit 1
fi

# --- sanity: binary + dylib linkage --------------------------------------
if [[ ! -x "${PW_BIN}" ]]; then
    echo "${C_RED}ERROR${C_RST}: PW_BIN not executable: ${PW_BIN}"
    exit 1
fi
if ! otool -L "${PW_BIN}" 2>/dev/null | grep -qE "applebottom|libab"; then
    echo "${C_RED}ERROR${C_RST}: pw.x not linked against libapplebottom.dylib"
    exit 1
fi

echo "[$(ts)] NP × OMP sweep on ${C_BLD}${SYSTEM}${C_RST}"
echo "[$(ts)] Grid: ${GRID}"
echo "[$(ts)] AB_MODE=auto  AB_CROSSOVER_FLOPS=${THRESHOLD}"
echo "[$(ts)] Input: ${INPUT_FILE}"
echo ""

# --- run one point -------------------------------------------------------
run_point() {
    local np="$1" omp="$2"
    local product=$((np * omp))
    local label="np${np}_omp${omp}"
    local out="${OUT_ROOT}/${label}"
    rm -rf "${out}"; mkdir -p "${out}"
    cp "${INPUT_FILE}" "${out}/scf.in"

    # Warn on E-core spillover (M2 Max: 8 P-cores, 4 E-cores)
    local warn=""
    if (( product > 8 )); then
        warn=" ${C_YLW}[spills to E-cores]${C_RST}"
    fi

    echo "${C_BLU}=== [$(ts)] QE ${SYSTEM} | NP=${np} OMP=${omp} (×${product})${warn} ===${C_RST}"
    local start end wall rc=0
    start=$(date +%s)
    local TO; TO="$(command -v gtimeout || command -v timeout || true)"
    (
        cd "${out}"
        ulimit -s unlimited 2>/dev/null || true
        env -i HOME="$HOME" PATH="$PATH" \
            OMP_NUM_THREADS="${omp}" \
            AB_MODE=auto \
            AB_CROSSOVER_FLOPS="${THRESHOLD}" \
            AB_PROFILE_FILE="${out}/gemm_profile.txt" \
            ${TO:+${TO} ${TIMEOUT}} \
            mpirun -np "${np}" "${PW_BIN}" -inp scf.in > scf.out 2>scf.err
    ) || rc=$?
    end=$(date +%s); wall=$((end - start))

    local status="OK" conv="no" etot="NA"
    if [[ ${rc} -ne 0 ]]; then
        if [[ ${rc} -eq 124 ]]; then status="TIMEOUT"; else status="FAIL(rc=${rc})"; fi
    fi
    grep -q "convergence has been achieved" "${out}/scf.out" 2>/dev/null && conv="yes"
    etot="$(grep '^! *total energy' "${out}/scf.out" 2>/dev/null | tail -1 | awk '{print $(NF-1)}')"
    [[ -z "${etot}" ]] && etot="NA"

    {
        echo "system=${SYSTEM}"
        echo "np=${np}"
        echo "omp=${omp}"
        echo "threshold=${THRESHOLD}"
        echo "status=${status}"
        echo "wall_seconds=${wall}"
        echo "total_energy_Ry=${etot}"
        echo "converged=${conv}"
        echo "timestamp=$(ts)"
    } > "${out}/summary.txt"

    if [[ -f "${out}/gemm_profile.txt" ]]; then
        awk 'NR>1 { g[$6]++; f[$6]+=$5 }
             END { for (k in g) printf "%s calls=%d total_MNK=%.2e\n",
                   (k==1?"gpu":"cpu"), g[k], f[k] }' \
            "${out}/gemm_profile.txt" > "${out}/gemm_summary.txt" || true
    fi

    local cc gc
    cc=$(grep '^cpu calls' "${out}/gemm_summary.txt" 2>/dev/null | awk '{print $2}' | sed 's/calls=//' || echo 0)
    gc=$(grep '^gpu calls' "${out}/gemm_summary.txt" 2>/dev/null | awk '{print $2}' | sed 's/calls=//' || echo 0)
    printf "    NP=%d OMP=%d  wall=%4ds  cpu_calls=%-5s  gpu_calls=%-5s  E=%-16s  [%s]\n" \
        "${np}" "${omp}" "${wall}" "${cc:-0}" "${gc:-0}" "${etot}" "${status}"

    echo "${np},${omp},${wall},${cc:-0},${gc:-0},${etot},${status}" >> "${CSV}"
}

for point in ${GRID}; do
    np="${point%%,*}"
    omp="${point##*,}"
    run_point "${np}" "${omp}"
done

# --- summary + winner selection ------------------------------------------
echo ""
echo "${C_BLD}=== NP × OMP sweep summary: QE ${SYSTEM} ===${C_RST}"
printf "  %-12s %-8s %-10s %-10s %-16s %-8s\n" "config" "wall_s" "cpu_calls" "gpu_calls" "total_E_Ry" "status"
# Print rows
tail -n +2 "${CSV}" | while IFS=, read -r np omp wall cc gc e status; do
    printf "  NP=%-2d OMP=%-2d  %-8s %-10s %-10s %-16s %-8s\n" \
        "${np}" "${omp}" "${wall}" "${cc}" "${gc}" "${e}" "${status}"
done

# --- cross-check: energy agreement across points -------------------------
# All OK-status points must agree on total_E to 1e-6 Ry. Disagreeing points
# are NOT eligible to win.
REF_E=$(awk -F, 'NR>1 && $7=="OK" && $6!="NA" {print $6; exit}' "${CSV}")
if [[ -z "${REF_E}" ]]; then
    echo "${C_RED}ERROR${C_RST}: no OK/converged runs to pick a winner from."
    exit 3
fi

DISAGREE=0
while IFS=, read -r np omp wall cc gc e status; do
    [[ "${status}" == "OK" ]] || continue
    [[ "${e}" == "NA" ]] && continue
    diff=$(python3 -c "print(abs(${e} - ${REF_E}))" 2>/dev/null || echo 1)
    bad=$(python3 -c "print(1 if ${diff} > 1e-6 else 0)" 2>/dev/null || echo 0)
    if [[ "${bad}" == "1" ]]; then
        echo "${C_YLW}WARN${C_RST}: NP=${np} OMP=${omp} energy ${e} differs from ref ${REF_E} by ${diff} Ry"
        DISAGREE=$((DISAGREE + 1))
    fi
done < <(tail -n +2 "${CSV}")

# --- pick winner: lowest wall among agreeing OK points -------------------
WINNER=$(awk -F, -v ref="${REF_E}" '
    NR>1 && $7=="OK" && $6!="NA" {
        d = ($6 > ref) ? $6 - ref : ref - $6
        if (d <= 1e-6) {
            if (best == "" || $3 < best_wall) { best = $1","$2; best_wall = $3 }
        }
    }
    END { if (best != "") print best","best_wall }
' "${CSV}")

if [[ -z "${WINNER}" ]]; then
    echo "${C_RED}ERROR${C_RST}: no eligible winner (all points disagreed on energy or failed)."
    exit 4
fi

W_NP="${WINNER%%,*}"
rest="${WINNER#*,}"
W_OMP="${rest%%,*}"
W_WALL="${rest##*,}"

echo ""
echo "${C_GRN}${C_BLD}WINNER${C_RST}: NP=${W_NP} OMP=${W_OMP}  wall=${W_WALL}s  (threshold=${THRESHOLD})"
{
    echo "system=${SYSTEM}"
    echo "np=${W_NP}"
    echo "omp=${W_OMP}"
    echo "threshold=${THRESHOLD}"
    echo "wall_seconds=${W_WALL}"
    echo "ref_energy_Ry=${REF_E}"
    echo "energy_disagreements=${DISAGREE}"
    echo "timestamp=$(ts)"
} > "${OUT_ROOT}/winner.txt"
echo ""
echo "Winner written to ${OUT_ROOT}/winner.txt"
echo "CSV: ${CSV}"
