#!/usr/bin/env bash
# bench_cpu_baselines.sh — AB_MODE=cpu runs at the layouts of the NP × OMP sweeps.
#
# Runs the same binary with apple-bottom's dispatcher forced to the CPU
# (AB_MODE=cpu) at the (NP, OMP) points below, and sets each against the
# AB_MODE=auto run of bench_qe_np_omp.sh at the same point: same parallelism,
# only the routing differs. Ratio = cpu_wall / auto_wall.
#
# Four points:
#   (si64_500b, NP=1 OMP=1)
#   (si64_500b, NP=2 OMP=2)
#   (si216,    NP=1 OMP=1)
#   (si216,    NP=2 OMP=2)
#
# Output: results/cpu_baselines/cpu_baselines.csv with columns:
#   system,np,omp,mode,wall_s,cpu_calls,gpu_calls,total_E_Ry,status,gpu_time_pct
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

OUT_ROOT="${HERE}/results/cpu_baselines"
mkdir -p "${OUT_ROOT}"
CSV="${OUT_ROOT}/cpu_baselines.csv"
if [[ ! -f "${CSV}" ]]; then
    echo "system,np,omp,mode,wall_s,cpu_calls,gpu_calls,total_E_Ry,status,gpu_time_pct" > "${CSV}"
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
            ${TO:+${TO} ${TIMEOUT}} \
            mpirun -np "${np}" "${AB_WITH_PROFILE}" "${out}/ab_profile" \
            "${PW_BIN}" -inp scf.in > scf.out 2>scf.err
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
    echo "${system},${np},${omp},${mode},${wall},${cc},${gc},${etot},${status},${gpct}" >> "${CSV}"
}

echo "[$(ts)] AB_MODE=cpu runs at the NP × OMP sweep's layouts"
echo "[$(ts)] CSV: ${CSV}"
echo ""

# Four cpu-mode points
run_point si64_500b 1 1 cpu
run_point si64_500b 2 2 cpu
run_point si216     1 1 cpu
run_point si216     2 2 cpu

# --- cpu/auto summary ----------------------------------------------------
echo ""
echo "${C_BLD}=== cpu against auto ===${C_RST}"
printf "  %-12s %-8s %-8s %-8s %-8s\n" "system" "config" "cpu_s" "auto_s" "cpu/auto"

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
