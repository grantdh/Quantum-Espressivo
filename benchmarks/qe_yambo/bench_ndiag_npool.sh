#!/usr/bin/env bash
# bench_ndiag_npool.sh — AB_MODE=auto against AB_MODE=cpu with -ndiag 1 and -npool.
#
# Four targeted points at NP=4 OMP=1 on a single system:
#   (auto, -ndiag 1)  serial subspace diagonalization
#   (cpu,  -ndiag 1)  matched CPU baseline — ratio = cpu/auto
#   (auto, -npool 4)  k-point pool parallelism, serial diag per rank
#   (cpu,  -npool 4)  matched CPU baseline
#
# The CSV records apple-bottom's GPU and CPU calls and the GPU share of their
# time, summed over ranks, for each point.
#
# Output: results/ndiag_npool/ndiag_npool.csv with columns
#   system,np,omp,mode,flag,wall_s,cpu_calls,gpu_calls,total_E_Ry,status,gpu_time_pct
#
# Usage:
#   ./bench_ndiag_npool.sh [--system si64] [--np 4] [--timeout 1800]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/config.sh"

SYSTEM="si64"
NPR=4
OMP_N=1
TIMEOUT="1800"
SKIP_NPOOL=0
SKIP_NDIAG=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --system)      SYSTEM="$2";  shift 2 ;;
        --np)          NPR="$2";     shift 2 ;;
        --omp)         OMP_N="$2";   shift 2 ;;
        --timeout)     TIMEOUT="$2"; shift 2 ;;
        --skip-npool)  SKIP_NPOOL=1; shift ;;
        --skip-ndiag)  SKIP_NDIAG=1; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# Auto-detect 1-k-point systems from the input and skip npool there.
# (nk1=1 nk2=1 nk3=1 means a single Γ-point calculation — npool parallelism
# is a no-op on those systems, so don't waste runtime on it.)
if [[ ${SKIP_NPOOL} -eq 0 ]] && [[ -f "${BENCH_INPUT_DIR}/${SYSTEM}/scf.in" ]]; then
    kline=$(grep -E '^\s*[0-9]+\s+[0-9]+\s+[0-9]+\s+[0-9]+\s+[0-9]+\s+[0-9]+\s*$' \
        "${BENCH_INPUT_DIR}/${SYSTEM}/scf.in" | tail -1 || true)
    if [[ -n "${kline}" ]]; then
        read -r nk1 nk2 nk3 _ <<< "${kline}"
        if [[ "${nk1}${nk2}${nk3}" == "111" ]]; then
            echo "${C_YLW}note${C_RST}: ${SYSTEM} uses a 1×1×1 k-grid — auto-skipping -npool runs"
            SKIP_NPOOL=1
        fi
    fi
fi

OUT_ROOT="${HERE}/results/ndiag_npool"
mkdir -p "${OUT_ROOT}"
CSV="${OUT_ROOT}/ndiag_npool.csv"
if [[ ! -f "${CSV}" ]]; then
    echo "system,np,omp,mode,flag,wall_s,cpu_calls,gpu_calls,total_E_Ry,status,gpu_time_pct" > "${CSV}"
fi

INPUT="${BENCH_INPUT_DIR}/${SYSTEM}/scf.in"
if [[ ! -f "${INPUT}" ]]; then
    echo "${C_RED}ERROR${C_RST}: no input at ${INPUT}"; exit 1
fi
if ! otool -L "${PW_BIN}" 2>/dev/null | grep -qE "applebottom|libab"; then
    echo "${C_RED}ERROR${C_RST}: pw.x not linked against libapplebottom.dylib"; exit 1
fi

# --- run one point -------------------------------------------------------
run_point() {
    local mode="$1" flag_name="$2" flag_val="$3"
    local label="${SYSTEM}_np${NPR}_omp${OMP_N}_${mode}_${flag_name}${flag_val}"
    local out="${OUT_ROOT}/${label}"
    rm -rf "${out}"; mkdir -p "${out}"
    cp "${INPUT}" "${out}/scf.in"

    echo "${C_BLU}=== [$(ts)] ${SYSTEM} NP=${NPR} OMP=${OMP_N} AB_MODE=${mode} -${flag_name} ${flag_val} ===${C_RST}"
    local start end wall rc=0
    start=$(date +%s)
    local TO; TO="$(command -v gtimeout || command -v timeout || true)"
    (
        cd "${out}"
        ulimit -s unlimited 2>/dev/null || true
        env -i HOME="$HOME" PATH="$PATH" \
            OMP_NUM_THREADS="${OMP_N}" \
            AB_MODE="${mode}" \
            AB_CROSSOVER_FLOPS=100000000 \
            ${TO:+${TO} ${TIMEOUT}} \
            mpirun -np "${NPR}" "${AB_WITH_PROFILE}" "${out}/ab_profile" \
            "${PW_BIN}" -${flag_name} "${flag_val}" -inp scf.in > scf.out 2>scf.err
    ) || rc=$?
    end=$(date +%s); wall=$((end - start))

    local status="OK" etot="NA"
    if [[ ${rc} -ne 0 ]]; then
        if [[ ${rc} -eq 124 ]]; then status="TIMEOUT"; else status="FAIL(rc=${rc})"; fi
    fi
    etot="$(grep '^! *total energy' "${out}/scf.out" 2>/dev/null | tail -1 | awk '{print $(NF-1)}')"
    [[ -z "${etot}" ]] && etot="NA"

    local gc cc gpct build
    read -r gc cc gpct build <<< "$(ab_summary "${out}/ab_profile")"

    printf "    wall=%5ds  cpu_calls=%-5s  gpu_calls=%-5s  gpu_time=%s%%  E=%-16s  [%s]\n" \
        "${wall}" "${cc}" "${gc}" "${gpct}" "${etot}" "${status}"
    echo "${SYSTEM},${NPR},${OMP_N},${mode},-${flag_name}=${flag_val},${wall},${cc},${gc},${etot},${status},${gpct}" >> "${CSV}"
}

echo "[$(ts)] -ndiag 1 / -npool runs on ${SYSTEM} at NP=${NPR} OMP=${OMP_N}"
echo "[$(ts)] CSV: ${CSV}"
echo ""

if [[ ${SKIP_NDIAG} -eq 0 ]]; then
    run_point auto ndiag 1
    run_point cpu  ndiag 1
fi
if [[ ${SKIP_NPOOL} -eq 0 ]]; then
    run_point auto npool "${NPR}"
    run_point cpu  npool "${NPR}"
fi

# --- summary ------------------------------------------------------------
echo ""
echo "${C_BLD}=== Summary: ${SYSTEM} at NP=${NPR} ===${C_RST}"
printf "  %-22s %-8s %-10s %-10s %-8s\n" "config" "wall_s" "cpu_calls" "gpu_calls" "cpu/auto"

get_wall() {
    awk -F, -v s="${SYSTEM}" -v n="${NPR}" -v o="${OMP_N}" -v m="$1" -v f="$2" \
        'NR>1 && $1==s && $2==n && $3==o && $4==m && $5==f {print $6; exit}' "${CSV}"
}

PAIRS=()
[[ ${SKIP_NDIAG} -eq 0 ]] && PAIRS+=("ndiag=1")
[[ ${SKIP_NPOOL} -eq 0 ]] && PAIRS+=("npool=${NPR}")
for pair in "${PAIRS[@]}"; do
    cw=$(get_wall "cpu"  "-${pair}")
    aw=$(get_wall "auto" "-${pair}")
    if [[ -n "${cw}" ]] && [[ -n "${aw}" ]]; then
        sp=$(python3 -c "print(f'{${cw}/${aw}:.2f}x')" 2>/dev/null || echo "NA")
    else
        sp="NA"
    fi
    printf "  -%-20s  auto=%-6s  cpu=%-6s  cpu/auto=%s\n" "${pair}" "${aw:-NA}" "${cw:-NA}" "${sp}"
done

echo ""
echo "CSV: ${CSV}"
