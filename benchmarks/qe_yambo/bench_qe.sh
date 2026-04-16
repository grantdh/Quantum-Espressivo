#!/usr/bin/env bash
# bench_qe.sh — run one QE SCF system in all three AB_MODE policies and
# validate that total energies agree to within conv_thr.
#
# Mode mechanics (NOT DYLD interposition — that approach is deprecated per
# CLAUDE.md. pw.x is explicitly linked against libapplebottom.dylib and
# reads AB_MODE at startup):
#   cpu  : AB_MODE=cpu                         → cblas/Accelerate only
#   gpu  : AB_MODE=gpu + AB_MIN_GPU_DIM=0      → force every GEMM to Metal GPU
#   auto : AB_MODE=auto                        → compiled-in threshold routing
#
# The three modes solve the same SCF; total energies MUST agree to conv_thr.
# This is the most important output — any divergence means apple-bottom has
# a numerical bug that must be fixed before we believe the timings.
#
# Usage: ./bench_qe.sh <system_id> [--timeout SECONDS]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/config.sh"

SYSTEM="${1:-}"
[[ -n "${SYSTEM}" ]] || { echo "Usage: $0 <system_id> [--timeout SECONDS]"; exit 1; }
shift || true

TIMEOUT="${QE_TIMEOUT}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout) TIMEOUT="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

OUT_ROOT="${HERE}/results/qe_${SYSTEM}"
mkdir -p "${OUT_ROOT}"

# --- locate input ---------------------------------------------------------
INPUT_FILE=""
if [[ -f "${BENCH_INPUT_DIR}/${SYSTEM}/scf.in" ]]; then
    INPUT_FILE="${BENCH_INPUT_DIR}/${SYSTEM}/scf.in"
elif INPUT_FILE="$(qe_input_file "${SYSTEM}")"; then
    :
else
    echo "${C_RED}ERROR${C_RST}: no input for '${SYSTEM}'. Run ./generate_inputs.sh first."
    exit 1
fi
echo "[$(ts)] Input: ${INPUT_FILE}"

# --- preflight: binary exists + links apple-bottom ------------------------
if [[ ! -x "${PW_BIN}" ]]; then
    echo "${C_RED}ERROR${C_RST}: PW_BIN not executable: ${PW_BIN}"
    echo "       Run ./build_qe_ab.sh first."
    exit 1
fi
if ! otool -L "${PW_BIN}" 2>/dev/null | grep -qE "applebottom|libab"; then
    echo "${C_RED}ERROR${C_RST}: ${PW_BIN} is NOT linked against libapplebottom.dylib."
    echo "       Modes 'gpu' and 'auto' would be indistinguishable from 'cpu'."
    echo "       Rebuild with ./build_qe_ab.sh and verify:  otool -L ${PW_BIN}"
    exit 1
fi
echo "${C_GRN}[linkage ok]${C_RST} $(otool -L "${PW_BIN}" | grep -E 'applebottom' | head -1 | awk '{print $1}')"
echo ""

# --- run one mode ---------------------------------------------------------
run_mode() {
    local mode="$1"
    local out="${OUT_ROOT}/${mode}"
    rm -rf "${out}"; mkdir -p "${out}"
    cp "${INPUT_FILE}" "${out}/scf.in"

    # Mode-specific env
    local AB_EXTRA=""
    case "${mode}" in
        cpu)  AB_EXTRA="AB_MODE=cpu" ;;
        gpu)  AB_EXTRA="AB_MODE=gpu AB_MIN_GPU_DIM=0" ;;
        auto) AB_EXTRA="AB_MODE=auto" ;;
        *) echo "bad mode: ${mode}"; return 2 ;;
    esac

    echo "${C_BLU}=== [$(ts)] QE ${SYSTEM} | AB_MODE=${mode} | np=${NP} omp=${OMP} | timeout=${TIMEOUT}s ===${C_RST}"
    local start end wall rc=0
    start=$(date +%s)
    # NOTE: ulimit -s unlimited keeps QE from stack-overflowing on large cells.
    # gtimeout is coreutils; plain `timeout` on macOS if installed.
    local TO
    TO="$(command -v gtimeout || command -v timeout || true)"
    (
        cd "${out}"
        ulimit -s unlimited || true
        env -i HOME="$HOME" PATH="$PATH" \
            OMP_NUM_THREADS="${OMP}" \
            ${AB_EXTRA} \
            AB_PROFILE_FILE="${out}/gemm_profile.txt" \
            ${TO:+${TO} ${TIMEOUT}} \
            mpirun -np "${NP}" "${PW_BIN}" -inp scf.in > scf.out 2>scf.err
    ) || rc=$?
    end=$(date +%s)
    wall=$((end - start))

    # --- capture results -------------------------------------------------
    local conv="no" etot="NA" pwscf_wall="NA" status="OK"
    if [[ ${rc} -ne 0 ]]; then
        if [[ ${rc} -eq 124 ]]; then status="TIMEOUT"
        else status="FAIL(rc=${rc})"
        fi
    fi
    if grep -q "convergence has been achieved" "${out}/scf.out" 2>/dev/null; then
        conv="yes"
    fi
    etot="$(grep '^! *total energy' "${out}/scf.out" 2>/dev/null | tail -1 \
            | awk '{print $(NF-1)}')"
    pwscf_wall="$(grep -E '^ *PWSCF *:' "${out}/scf.out" 2>/dev/null | tail -1 \
                  | awk '{for(i=1;i<=NF;i++) if($i=="WALL") print $(i-1)$i; }' \
                  | head -1)"
    [[ -z "${etot}" ]]       && etot="NA"
    [[ -z "${pwscf_wall}" ]] && pwscf_wall="NA"

    # summary.txt is the canonical per-mode record used by aggregate.sh
    {
        echo "system=${SYSTEM}"
        echo "mode=${mode}"
        echo "status=${status}"
        echo "wall_seconds=${wall}"
        echo "pwscf_wall=${pwscf_wall}"
        echo "total_energy_Ry=${etot}"
        echo "converged=${conv}"
        echo "timestamp=$(ts)"
    } > "${out}/summary.txt"
    echo "${wall}" > "${out}/wall_seconds.txt"

    # GEMM profile summary (if apple-bottom wrote one)
    if [[ -f "${out}/gemm_profile.txt" ]]; then
        awk 'NR>1 { g[$6]++; f[$6]+=$5 }
             END { for (k in g) printf "%s calls=%d total_MNK=%.2e\n",
                   (k==1?"gpu":"cpu"), g[k], f[k] }' \
            "${out}/gemm_profile.txt" > "${out}/gemm_summary.txt" || true
    fi

    local tag
    case "${status}" in
        OK)        tag="${C_GRN}${status}${C_RST}" ;;
        TIMEOUT)   tag="${C_YLW}${status}${C_RST}" ;;
        *)         tag="${C_RED}${status}${C_RST}" ;;
    esac
    printf "    %-6s  wall=%4ds  pwscf=%-10s  E=%-16s  conv=%-3s  [%s]\n" \
        "${mode}" "${wall}" "${pwscf_wall}" "${etot}" "${conv}" "${tag}"
    return 0
}

for mode in cpu gpu auto; do
    run_mode "${mode}"
done

# --- energy agreement check ----------------------------------------------
# All three modes solve the same SCF. Total energies must agree within
# conv_thr (1e-6 Ry). Any divergence is a numerical bug in apple-bottom.
CONV_THR_RY=1e-6
echo ""
echo "${C_BLD}[energy agreement check — tolerance ${CONV_THR_RY} Ry]${C_RST}"
e_cpu=$(grep '^total_energy_Ry=' "${OUT_ROOT}/cpu/summary.txt"  2>/dev/null | cut -d= -f2)
e_gpu=$(grep '^total_energy_Ry=' "${OUT_ROOT}/gpu/summary.txt"  2>/dev/null | cut -d= -f2)
e_aut=$(grep '^total_energy_Ry=' "${OUT_ROOT}/auto/summary.txt" 2>/dev/null | cut -d= -f2)

agreement="PASS"
if [[ "${e_cpu}" == "NA" || "${e_gpu}" == "NA" || "${e_aut}" == "NA" ]]; then
    agreement="SKIP (one or more runs failed)"
else
    agreement=$(awk -v a="${e_cpu}" -v b="${e_gpu}" -v c="${e_aut}" -v t="${CONV_THR_RY}" \
        'BEGIN { d1=a-b; if(d1<0)d1=-d1; d2=a-c; if(d2<0)d2=-d2;
                 if (d1<=t && d2<=t) print "PASS"; else printf "FAIL (|cpu-gpu|=%.3e, |cpu-auto|=%.3e)\n", d1, d2 }')
fi
echo "  cpu  : ${e_cpu}"
echo "  gpu  : ${e_gpu}"
echo "  auto : ${e_aut}"
case "${agreement}" in
    PASS*) echo "  ${C_GRN}${agreement}${C_RST}" ;;
    SKIP*) echo "  ${C_YLW}${agreement}${C_RST}" ;;
    *)     echo "  ${C_RED}${agreement}${C_RST}" ;;
esac
echo "agreement=${agreement}" > "${OUT_ROOT}/agreement.txt"

# --- per-system summary banner -------------------------------------------
echo ""
echo "${C_BLD}=== Summary: QE ${SYSTEM} ===${C_RST}"
printf "  %-6s  %-10s  %-16s  %-10s\n" "mode" "wall_s" "total_E_Ry" "status"
for m in cpu gpu auto; do
    s="${OUT_ROOT}/${m}/summary.txt"
    [[ -f "${s}" ]] || { printf "  %-6s  (missing)\n" "${m}"; continue; }
    w=$(grep ^wall_seconds= "${s}"      | cut -d= -f2)
    e=$(grep ^total_energy_Ry= "${s}"   | cut -d= -f2)
    st=$(grep ^status= "${s}"           | cut -d= -f2)
    printf "  %-6s  %-10s  %-16s  %-10s\n" "${m}" "${w}" "${e}" "${st}"
done
