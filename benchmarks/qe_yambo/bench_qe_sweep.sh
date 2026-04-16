#!/usr/bin/env bash
# bench_qe_sweep.sh — runtime-threshold sweep for AB_MODE=auto.
#
# Two knobs to sweep (both now wired as env vars after the Apr 2026 patch):
#   AB_CROSSOVER_FLOPS   — the FLOP threshold in fortran_bridge.c (this is the
#                          knob that actually controls QE's dispatch split).
#   AB_MIN_GPU_DIM       — the dim floor in blas_wrapper.c (gates the secondary
#                          check inside ab_*_blas once dispatched).
#
# PRE-FLIGHT CHECK (learned the hard way on 2026-04-14): before running the
# sweep, verify that varying the env var actually produces different dispatch
# counts in the profile. If it doesn't, the binary wasn't rebuilt after wiring
# the knob — abort early instead of wasting 25 minutes collecting identical data.
#
# Output: results/qe_<sys>/auto_<knob>_<value>/summary.txt
#
# Usage:
#   ./bench_qe_sweep.sh <system_id>
#       [--knob AB_CROSSOVER_FLOPS|AB_MIN_GPU_DIM]
#       [--values "1e7 5e7 1e8 5e8 1e9"]
#       [--timeout SECONDS]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/config.sh"

SYSTEM="${1:-}"
[[ -n "${SYSTEM}" ]] || { echo "Usage: $0 <system_id> [--knob KNOB] [--values \"...\"] [--timeout S]"; exit 1; }
shift || true

KNOB="AB_CROSSOVER_FLOPS"          # the one that actually matters for QE auto
VALUES=""
TIMEOUT="${QE_TIMEOUT}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --knob)    KNOB="$2"; shift 2 ;;
        --values)  VALUES="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done
# Sensible defaults per knob
if [[ -z "${VALUES}" ]]; then
    case "${KNOB}" in
        AB_CROSSOVER_FLOPS)  VALUES="10000000 50000000 100000000 500000000 1000000000" ;;  # 1e7..1e9
        AB_MIN_GPU_DIM)      VALUES="8 16 32 64 128" ;;
        *) echo "Unknown knob: ${KNOB}"; exit 1 ;;
    esac
fi

OUT_ROOT="${HERE}/results/qe_${SYSTEM}"
mkdir -p "${OUT_ROOT}"

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

if [[ ! -x "${PW_BIN}" ]]; then
    echo "${C_RED}ERROR${C_RST}: PW_BIN not executable: ${PW_BIN}"
    exit 1
fi
if ! otool -L "${PW_BIN}" 2>/dev/null | grep -qE "applebottom|libab"; then
    echo "${C_RED}ERROR${C_RST}: pw.x not linked against libapplebottom.dylib"
    exit 1
fi

# --- PRE-FLIGHT: verify knob is actually wired into the binary -----------
# Search the dylib's string table for the env var name. If it's absent, the
# binary predates the wiring patch and varying the value is pointless.
echo "[$(ts)] ${C_BLU}pre-flight${C_RST}: checking ${KNOB} is wired into ${AB_LIB}"
if ! strings "${AB_LIB}" 2>/dev/null | grep -q "^${KNOB}$"; then
    echo "${C_RED}ERROR${C_RST}: '${KNOB}' not found in ${AB_LIB}."
    echo "  The env var is likely not wired in the current build."
    echo "  Fix: cd ${AB_ROOT} && make clean && make && make dylib && make test"
    echo "       then re-run ./build_qe_ab.sh to relink pw.x (clean dylib pickup)."
    exit 1
fi
echo "  ${C_GRN}ok${C_RST} — '${KNOB}' symbol present in dylib"

echo ""
echo "[$(ts)] Sweep: ${C_BLD}${KNOB}${C_RST} ∈ { ${VALUES} }"
echo "[$(ts)] Input: ${INPUT_FILE}"
echo ""

# --- run one value --------------------------------------------------------
run_value() {
    local val="$1"
    local label="auto_$(echo "${KNOB}" | sed 's/^AB_//' | tr 'A-Z' 'a-z')_${val}"
    local out="${OUT_ROOT}/${label}"
    rm -rf "${out}"; mkdir -p "${out}"
    cp "${INPUT_FILE}" "${out}/scf.in"

    echo "${C_BLU}=== [$(ts)] QE ${SYSTEM} | AB_MODE=auto ${KNOB}=${val} ===${C_RST}"
    local start end wall rc=0
    start=$(date +%s)
    local TO; TO="$(command -v gtimeout || command -v timeout || true)"
    (
        cd "${out}"
        ulimit -s unlimited 2>/dev/null || true
        env -i HOME="$HOME" PATH="$PATH" \
            OMP_NUM_THREADS="${OMP}" \
            AB_MODE=auto "${KNOB}=${val}" \
            AB_PROFILE_FILE="${out}/gemm_profile.txt" \
            ${TO:+${TO} ${TIMEOUT}} \
            mpirun -np "${NP}" "${PW_BIN}" -inp scf.in > scf.out 2>scf.err
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
        echo "mode=${label}"
        echo "knob=${KNOB}"
        echo "knob_value=${val}"
        echo "status=${status}"
        echo "wall_seconds=${wall}"
        echo "total_energy_Ry=${etot}"
        echo "converged=${conv}"
        echo "timestamp=$(ts)"
    } > "${out}/summary.txt"
    echo "${wall}" > "${out}/wall_seconds.txt"

    if [[ -f "${out}/gemm_profile.txt" ]]; then
        awk 'NR>1 { g[$6]++; f[$6]+=$5 }
             END { for (k in g) printf "%s calls=%d total_MNK=%.2e\n",
                   (k==1?"gpu":"cpu"), g[k], f[k] }' \
            "${out}/gemm_profile.txt" > "${out}/gemm_summary.txt" || true
    fi

    local cpu_calls gpu_calls
    cpu_calls=$(grep '^cpu calls' "${out}/gemm_summary.txt" 2>/dev/null | awk '{print $2}' | sed 's/calls=//' || echo 0)
    gpu_calls=$(grep '^gpu calls' "${out}/gemm_summary.txt" 2>/dev/null | awk '{print $2}' | sed 's/calls=//' || echo 0)
    printf "    %-18s  wall=%4ds  cpu_calls=%-5s  gpu_calls=%-5s  E=%-16s  [%s]\n" \
        "${KNOB}=${val}" "${wall}" "${cpu_calls:-0}" "${gpu_calls:-0}" "${etot}" "${status}"
}

# --- DYNAMIC PRE-FLIGHT: first run of the sweep establishes a baseline.
# After the 2nd run completes (at a very different knob value), we diff the
# dispatch counts. If they're identical, the knob is a no-op — abort the rest
# of the sweep.
PREV_COUNTS=""
i=0
for v in ${VALUES}; do
    run_value "${v}"
    i=$((i + 1))
    if [[ ${i} -eq 2 ]]; then
        last_dir=$(ls -dt "${OUT_ROOT}"/auto_*_* 2>/dev/null | head -1)
        prev_dir=$(ls -dt "${OUT_ROOT}"/auto_*_* 2>/dev/null | sed -n 2p)
        c1=$(cat "${last_dir}/gemm_summary.txt" 2>/dev/null | sort)
        c2=$(cat "${prev_dir}/gemm_summary.txt" 2>/dev/null | sort)
        if [[ -n "${c1}" ]] && [[ "${c1}" == "${c2}" ]]; then
            echo ""
            echo "${C_RED}[abort]${C_RST} dispatch counts identical between first two values —"
            echo "        ${KNOB} is not changing behavior. Aborting sweep."
            echo "        Runs completed: ${i}. Output in ${OUT_ROOT}/"
            exit 2
        fi
    fi
done

# --- sweep summary -------------------------------------------------------
echo ""
echo "${C_BLD}=== Sweep summary: QE ${SYSTEM} (${KNOB}) ===${C_RST}"
printf "  %-28s %-8s %-10s %-10s %-16s\n" "config" "wall_s" "cpu_calls" "gpu_calls" "total_E_Ry"
# Include cpu/gpu/auto baselines at top if present
for m in cpu gpu auto; do
    s="${OUT_ROOT}/${m}/summary.txt"
    [[ -f "${s}" ]] || continue
    w=$(grep ^wall_seconds= "${s}" | cut -d= -f2)
    e=$(grep ^total_energy_Ry= "${s}" | cut -d= -f2)
    gs="${OUT_ROOT}/${m}/gemm_summary.txt"
    cc=$(grep '^cpu calls' "${gs}" 2>/dev/null | awk '{print $2}' | sed 's/calls=//' || true)
    gc=$(grep '^gpu calls' "${gs}" 2>/dev/null | awk '{print $2}' | sed 's/calls=//' || true)
    printf "  %-28s %-8s %-10s %-10s %-16s\n" "baseline:${m}" "${w}" "${cc:-0}" "${gc:-0}" "${e}"
done
for v in ${VALUES}; do
    label="auto_$(echo "${KNOB}" | sed 's/^AB_//' | tr 'A-Z' 'a-z')_${v}"
    s="${OUT_ROOT}/${label}/summary.txt"
    [[ -f "${s}" ]] || continue
    w=$(grep ^wall_seconds= "${s}" | cut -d= -f2)
    e=$(grep ^total_energy_Ry= "${s}" | cut -d= -f2)
    gs="${OUT_ROOT}/${label}/gemm_summary.txt"
    cc=$(grep '^cpu calls' "${gs}" 2>/dev/null | awk '{print $2}' | sed 's/calls=//' || true)
    gc=$(grep '^gpu calls' "${gs}" 2>/dev/null | awk '{print $2}' | sed 's/calls=//' || true)
    printf "  %-28s %-8s %-10s %-10s %-16s\n" "${KNOB}=${v}" "${w}" "${cc:-0}" "${gc:-0}" "${e}"
done
