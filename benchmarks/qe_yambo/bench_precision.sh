#!/usr/bin/env bash
# bench_precision.sh — NP-invariance of total energy (the paper's precision claim).
#
# Runs the same SCF across multiple parallelism configs in BOTH modes:
#   AB_MODE=auto (apple-bottom DD path)
#   AB_MODE=cpu  (Accelerate ZGEMM under apple-bottom's dispatcher)
#
# The claim: apple-bottom's DD emulation produces smaller (ideally zero)
# total-energy drift across NP than Accelerate's FP32-accumulator path.
#
# For each mode we compute the max pairwise |delta_E| across NP configs.
# Ratio = delta_E_cpu / delta_E_auto. If > ~10×, the precision claim is
# strongly supported. If ~1×, the claim is weak and we need a different
# angle for the paper.
#
# Configs tested (si216 by default — largest system has largest accumulation):
#   NP=1 OMP=1 (plain)
#   NP=2 OMP=2 (default auto)
#   NP=4 OMP=1 -ndiag 1
#   NP=8 OMP=1 -ndiag 1
#
# Output: results/paper_precision/precision.csv + printed summary table
# Runtime: ~3-4h on si216, ~15 min on si64.
#
# Usage:
#   ./bench_precision.sh [--system si216] [--timeout 7200]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/config.sh"

SYSTEM="si216"
TIMEOUT="7200"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --system)  SYSTEM="$2";  shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

INPUT="${BENCH_INPUT_DIR}/${SYSTEM}/scf.in"
[[ -f "${INPUT}" ]] || { echo "${C_RED}ERROR${C_RST}: no input at ${INPUT}"; exit 1; }
otool -L "${PW_BIN}" 2>/dev/null | grep -qE "applebottom|libab" || {
    echo "${C_RED}ERROR${C_RST}: pw.x not linked against libapplebottom.dylib"; exit 1
}

OUT_ROOT="${HERE}/results/paper_precision"
mkdir -p "${OUT_ROOT}"
CSV="${OUT_ROOT}/precision.csv"
[[ -f "${CSV}" ]] || echo "system,np,omp,mode,extra_flags,wall_s,total_E_Ry,status" > "${CSV}"

# Configs: label | np | omp | extra flags (space-separated)
CONFIGS=(
    "plain1     1 1"
    "plain2     2 2"
    "ndiag1_4   4 1 -ndiag 1"
    "ndiag1_8   8 1 -ndiag 1"
)

run_point() {
    local label="$1" mode="$2" np="$3" omp="$4"; shift 4
    local extra_flags=("$@")
    local tag="${SYSTEM}_${label}_${mode}"
    local out="${OUT_ROOT}/${tag}"
    rm -rf "${out}"; mkdir -p "${out}"
    cp "${INPUT}" "${out}/scf.in"

    local _flags_disp=""
    [[ ${#extra_flags[@]} -gt 0 ]] && _flags_disp="${extra_flags[*]}"
    echo "${C_BLU}=== [$(ts)] ${SYSTEM} ${label} NP=${np} OMP=${omp} AB_MODE=${mode} ${_flags_disp} ===${C_RST}"
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
            mpirun -np "${np}" "${PW_BIN}" ${extra_flags[@]+"${extra_flags[@]}"} -inp scf.in > scf.out 2>scf.err
    ) || rc=$?
    end=$(date +%s); wall=$((end - start))

    local status="OK" etot="NA"
    if [[ ${rc} -ne 0 ]]; then
        if [[ ${rc} -eq 124 ]]; then status="TIMEOUT"; else status="FAIL(rc=${rc})"; fi
    fi
    # Extract total energy to the full displayed precision QE writes.
    etot="$(grep '^! *total energy' "${out}/scf.out" 2>/dev/null | tail -1 | awk '{print $(NF-1)}')"
    [[ -z "${etot}" ]] && etot="NA"

    printf "    wall=%5ds  E=%-20s  [%s]\n" "${wall}" "${etot}" "${status}"
    local flags_csv=""
    if [[ ${#extra_flags[@]} -gt 0 ]]; then
        flags_csv="$(IFS=' '; echo "${extra_flags[*]}")"
    fi
    echo "${SYSTEM},${np},${omp},${mode},${flags_csv},${wall},${etot},${status}" >> "${CSV}"
}

echo "[$(ts)] Precision validation on ${SYSTEM}"
echo "[$(ts)] CSV: ${CSV}"
echo ""

# Run auto mode first (fast enough to fail early if something's broken),
# then cpu mode for matched comparison.
for mode in auto cpu; do
    echo "${C_BLD}---- AB_MODE=${mode} ----${C_RST}"
    for cfg in "${CONFIGS[@]}"; do
        read -r label np omp rest <<< "${cfg}"
        extra=()
        if [[ -n "${rest:-}" ]]; then
            read -ra extra <<< "${rest}"
        fi
        run_point "${label}" "${mode}" "${np}" "${omp}" ${extra[@]+"${extra[@]}"}
    done
done

# --- precision analysis ---------------------------------------------------
echo ""
echo "${C_BLD}=== Precision analysis: ${SYSTEM} ===${C_RST}"

python3 - "${CSV}" "${SYSTEM}" <<'PY'
import csv, sys
from collections import defaultdict

csv_path, system = sys.argv[1], sys.argv[2]
by_mode = defaultdict(list)  # mode -> [(label_desc, E, wall)]
with open(csv_path) as f:
    r = csv.DictReader(f)
    for row in r:
        if row["system"] != system or row["status"] != "OK":
            continue
        try:
            E = float(row["total_E_Ry"])
        except ValueError:
            continue
        label = f"NP={row['np']} OMP={row['omp']} {row['extra_flags']}".strip()
        by_mode[row["mode"]].append((label, E, int(row["wall_s"])))

print(f"  {'mode':<6} {'config':<28} {'total_E (Ry)':<20} {'wall_s'}")
for mode in ("auto", "cpu"):
    rows = by_mode.get(mode, [])
    if not rows: continue
    for label, E, wall in rows:
        print(f"  {mode:<6} {label:<28} {E:<20.10f} {wall}")
    print()

def span(vals):
    if len(vals) < 2: return 0.0
    return max(vals) - min(vals)

auto_Es = [E for _,E,_ in by_mode.get("auto", [])]
cpu_Es  = [E for _,E,_ in by_mode.get("cpu",  [])]
auto_span = span(auto_Es)
cpu_span  = span(cpu_Es)

print(f"  max |delta_E| across NP in AB_MODE=auto: {auto_span:.2e} Ry")
print(f"  max |delta_E| across NP in AB_MODE=cpu:  {cpu_span:.2e} Ry")
if auto_span > 0:
    ratio = cpu_span / auto_span
    print(f"  ratio (cpu / auto): {ratio:.2f}×")
    if ratio >= 10:
        print(f"  >>> STRONG precision claim: apple-bottom ~{ratio:.0f}× more NP-stable than Accelerate")
    elif ratio >= 3:
        print(f"  >>> MODEST precision claim: apple-bottom ~{ratio:.1f}× more NP-stable")
    else:
        print(f"  >>> WEAK precision claim: apple-bottom's NP-stability edge is < 3×")
elif cpu_span > 0:
    print(f"  >>> IDEAL precision claim: auto is bit-identical across NP; cpu drifts {cpu_span:.2e} Ry")
else:
    print(f"  >>> Both modes bit-identical — precision claim cannot be distinguished at QE's display precision")
PY

echo ""
echo "CSV: ${CSV}"
