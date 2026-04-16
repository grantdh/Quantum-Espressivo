#!/usr/bin/env bash
# run_overnight.sh — unattended overnight QE benchmark pipeline.
#
# Stages:
#   0. Sanity: otool check + dylib knob check
#   1. NP × OMP sweep on larger systems (si64_500b, si216) using their
#      per-system reduced grids. si64 was already characterized in
#      results/qe_si64_nposmp/ and is not re-run.
#   2. Collect results + write REPORT.md.
#
# Per-system grids are reduced to skip redundant "scalapack eats everything"
# configurations. NP=4 OMP=2 and NP=8 on the largest system are omitted on
# the theory that scalapack bypasses apple-bottom at NP≥2 regardless of
# system size, so those points just confirm the same architectural finding.
#
# Designed to run unattended. Failures in one system don't block the next.
#
# Usage:
#   ./run_overnight.sh [--threshold N] [--systems "si64_500b si216"]
#       [--timeout SECONDS_PER_POINT]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/config.sh"

THRESHOLD="100000000"
SYSTEMS="si64_500b si216"
TIMEOUT_PER_POINT="7200"   # 2h per single SCF — generous for si216 NP=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --threshold) THRESHOLD="$2";       shift 2 ;;
        --systems)   SYSTEMS="$2";         shift 2 ;;
        --timeout)   TIMEOUT_PER_POINT="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# Per-system grid: (trimmed based on si64 learning that scalapack eats work at NP≥2)
grid_for() {
    case "$1" in
        si64_500b) echo "1,1 1,4 2,2 4,1 8,1" ;;
        si216)     echo "1,1 1,4 2,2 4,1" ;;       # skip NP=8 (atoms/rank too small)
        *)         echo "1,1 1,4 2,2 4,1" ;;
    esac
}

STAMP="$(date +%Y%m%d-%H%M)"
OVN="${HERE}/results/overnight-${STAMP}"
mkdir -p "${OVN}"
LOG="${OVN}/overnight.log"
exec > >(tee -a "${LOG}") 2>&1

banner() { echo ""; echo "${C_BLD}========== $1 ==========${C_RST}"; }
fail()   { echo "${C_RED}[stage failure]${C_RST} $*" | tee -a "${OVN}/FAILURES.txt"; }

echo "[$(ts)] overnight start  -> ${OVN}"
echo "[$(ts)] threshold=${THRESHOLD}  systems='${SYSTEMS}'  timeout/point=${TIMEOUT_PER_POINT}s"

# ========================================================================
# Stage 0: sanity
# ========================================================================
banner "Stage 0: sanity"
S0_OK=1
if ! otool -L "${PW_BIN}" 2>/dev/null | grep -qE "applebottom|libab"; then
    fail "pw.x (${PW_BIN}) not linked against libapplebottom.dylib"; S0_OK=0
else
    echo "  ${C_GRN}ok${C_RST} — pw.x links apple-bottom"
fi
if ! strings "${AB_LIB}" 2>/dev/null | grep -qE '^AB_(CROSSOVER_FLOPS|MIN_GPU_DIM|MODE)$'; then
    fail "dylib missing one of AB_MODE / AB_CROSSOVER_FLOPS / AB_MIN_GPU_DIM symbols"; S0_OK=0
else
    echo "  ${C_GRN}ok${C_RST} — dylib has all env-var knobs wired"
fi
for s in ${SYSTEMS}; do
    if [[ ! -f "${BENCH_INPUT_DIR}/${s}/scf.in" ]]; then
        fail "missing input: ${BENCH_INPUT_DIR}/${s}/scf.in — run ./generate_inputs.sh"
        S0_OK=0
    fi
done
if [[ ${S0_OK} -eq 0 ]]; then
    echo "${C_RED}abort:${C_RST} stage 0 failed. Fix issues above and retry."
    exit 1
fi
echo "  ${C_GRN}ok${C_RST} — inputs present for: ${SYSTEMS}"

# ========================================================================
# Stage 1: per-system NP × OMP sweeps
# ========================================================================
SUMMARIES=""
for s in ${SYSTEMS}; do
    G="$(grid_for "${s}")"
    banner "Stage 1: NP × OMP sweep on ${s} (grid: ${G})"
    LOG_S="${OVN}/${s}_nposmp.log"
    if "${HERE}/bench_qe_np_omp.sh" "${s}" \
            --threshold "${THRESHOLD}" \
            --grid "${G}" \
            --timeout "${TIMEOUT_PER_POINT}" \
            > "${LOG_S}" 2>&1; then
        echo "  ${C_GRN}ok${C_RST} — sweep completed for ${s}"
    else
        fail "sweep failed for ${s} — see ${LOG_S} (partial CSV may still exist)"
    fi
    # Always copy whatever results exist (partial runs still useful)
    SRC="${HERE}/results/qe_${s}_nposmp"
    if [[ -d "${SRC}" ]]; then
        cp -r "${SRC}" "${OVN}/${s}_nposmp" || true
        [[ -f "${SRC}/nposmp.csv" ]] && cp "${SRC}/nposmp.csv" "${OVN}/${s}_nposmp.csv" || true
        [[ -f "${SRC}/winner.txt" ]] && cp "${SRC}/winner.txt" "${OVN}/${s}_winner.txt" || true
    fi
    SUMMARIES="${SUMMARIES} ${s}"
done

# ========================================================================
# REPORT
# ========================================================================
banner "Writing REPORT.md"
{
    echo "# Overnight QE benchmark — ${STAMP}"
    echo ""
    echo "- Host: M2 Max (8 P-cores + 4 E-cores, 30/38-core GPU, 400 GB/s, 96 GB)"
    echo "- pw.x: \`${PW_BIN}\`"
    echo "- libapplebottom: \`${AB_LIB}\`"
    echo "- AB_CROSSOVER_FLOPS: ${THRESHOLD}"
    echo "- Per-point timeout: ${TIMEOUT_PER_POINT}s"
    echo ""
    echo "## Architectural note"
    echo ""
    echo "The si64 sweep established that at NP≥2, ScaLAPACK's parallel"
    echo "eigensolvers handle the dominant GEMM work and bypass apple-bottom's"
    echo "patched call sites in QE. Expected symptom on si64_500b / si216 at"
    echo "NP≥2: \`cpu_calls=0 gpu_calls=0\` (not a bug). The paper-relevant"
    echo "apple-bottom numbers are the NP=1 rows."
    echo ""
    for s in ${SUMMARIES}; do
        echo "## ${s}"
        echo ""
        if [[ -f "${OVN}/${s}_nposmp.csv" ]]; then
            echo '```'
            cat "${OVN}/${s}_nposmp.csv"
            echo '```'
        else
            echo "_no CSV produced — see ${s}_nposmp.log_"
        fi
        if [[ -f "${OVN}/${s}_winner.txt" ]]; then
            echo ""
            echo "**Winner:**"
            echo '```'
            cat "${OVN}/${s}_winner.txt"
            echo '```'
        fi
        echo ""
    done
    if [[ -f "${OVN}/FAILURES.txt" ]]; then
        echo "## Failures"
        echo ""
        echo '```'
        cat "${OVN}/FAILURES.txt"
        echo '```'
    fi
    echo ""
    echo "## Artifacts"
    echo ""
    echo "- Full log: \`overnight.log\`"
    for s in ${SUMMARIES}; do
        echo "- ${s} log: \`${s}_nposmp.log\`"
        echo "- ${s} results dir: \`${s}_nposmp/\`"
    done
} > "${OVN}/REPORT.md"

echo ""
echo "${C_GRN}${C_BLD}Overnight pipeline complete.${C_RST}"
echo "Report: ${OVN}/REPORT.md"
