#!/usr/bin/env bash
# bench_qe_np_omp.sh — 6-point NP × OMP sweep.
#
# Runs QE SCF under AB_MODE=auto at fixed AB_CROSSOVER_FLOPS (a FLOP threshold
# that replaces apple-bottom's calibrated table), varying only (NP, OMP).
# Single trial per point.
#
# Keep NP × OMP ≤ the number of performance cores (hw.perflevel0; 8 on an
# M2 Max) to stay off the efficiency cores; points above it are flagged.
#
# Grid:
#   (1,1)  baseline                               — single-rank, single-thread
#   (1,4)  single GPU context + OMP on CPU calls  — OMP scaling test
#   (2,2)  balanced                               — 2 GPU contexts, moderate OMP
#   (4,1)  pure MPI                               — 4 GPU contexts
#   (4,2)  NP × OMP = 8                           — all P-cores of an M2 Max
#   (8,1)  max MPI, GPU context contention        — tests ceiling
#
# Output: results/qe_<sys>_nposmp/np<N>_omp<M>/summary.txt + nposmp.csv, with
# apple-bottom's GPU and CPU calls and the GPU share of their time, summed over ranks
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
echo "np,omp,wall_s,cpu_calls,gpu_calls,total_E_Ry,status,gpu_time_pct" > "${CSV}"

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

    # Warn on E-core spillover
    local warn=""
    if (( P_CORES > 0 && product > P_CORES )); then
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
            ${TO:+${TO} ${TIMEOUT}} \
            mpirun -np "${np}" "${AB_WITH_PROFILE}" "${out}/ab_profile" \
            "${PW_BIN}" -inp scf.in > scf.out 2>scf.err
    ) || rc=$?
    end=$(date +%s); wall=$((end - start))

    local status="OK" conv="no" etot="NA"
    if [[ ${rc} -ne 0 ]]; then
        if [[ ${rc} -eq 124 ]]; then status="TIMEOUT"; else status="FAIL(rc=${rc})"; fi
    fi
    grep -q "convergence has been achieved" "${out}/scf.out" 2>/dev/null && conv="yes"
    etot="$(grep '^! *total energy' "${out}/scf.out" 2>/dev/null | tail -1 | awk '{print $(NF-1)}')"
    [[ -z "${etot}" ]] && etot="NA"
    local gc cc gpct build
    read -r gc cc gpct build <<< "$(ab_summary "${out}/ab_profile")"

    {
        echo "system=${SYSTEM}"
        echo "np=${np}"
        echo "omp=${omp}"
        echo "threshold=${THRESHOLD}"
        echo "status=${status}"
        echo "wall_seconds=${wall}"
        echo "total_energy_Ry=${etot}"
        echo "converged=${conv}"
        ab_kv "${gc}" "${cc}" "${gpct}" "${build}"
        echo "timestamp=$(ts)"
    } > "${out}/summary.txt"
    printf "    NP=%d OMP=%d  wall=%4ds  cpu_calls=%-5s  gpu_calls=%-5s  gpu_time=%s%%  E=%-16s  [%s]\n" \
        "${np}" "${omp}" "${wall}" "${cc}" "${gc}" "${gpct}" "${etot}" "${status}"

    echo "${np},${omp},${wall},${cc},${gc},${etot},${status},${gpct}" >> "${CSV}"
}

for point in ${GRID}; do
    np="${point%%,*}"
    omp="${point##*,}"
    run_point "${np}" "${omp}"
done

# --- summary + winner selection ------------------------------------------
echo ""
echo "${C_BLD}=== NP × OMP sweep summary: QE ${SYSTEM} ===${C_RST}"
printf "  %-12s %-8s %-10s %-10s %-9s %-16s %-8s\n" "config" "wall_s" "cpu_calls" "gpu_calls" "gpu_time" "total_E_Ry" "status"
# Print rows
tail -n +2 "${CSV}" | while IFS=, read -r np omp wall cc gc e status gpct; do
    printf "  NP=%-2d OMP=%-2d  %-8s %-10s %-10s %-9s %-16s %-8s\n" \
        "${np}" "${omp}" "${wall}" "${cc}" "${gc}" "${gpct}%" "${e}" "${status}"
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
while IFS=, read -r np omp wall cc gc e status gpct; do
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
