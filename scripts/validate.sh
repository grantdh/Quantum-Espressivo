#!/bin/bash
# validate.sh — check that QE gives the same answers with its GEMMs on the GPU
#
# Usage:
#   ./scripts/validate.sh [--input file.in] [--pw path/to/pw.x]
#
# Runs one apple-bottom-linked pw.x (build-qe-metal.sh's) twice on the same input, as
# apple-bottom's VAL-1 does: with AB_MODE=cpu (every GEMM on Accelerate) and with AB_MODE=gpu
# (every GEMM whose dimensions all exceed AB_MIN_GPU_DIM on the GPU), recording apple-bottom's
# profile of both. It passes if the two runs converge in the same number of SCF iterations to
# final total energies within TOL_RY (default 1e-6 Ry, VAL-1's criterion), and apple-bottom
# received the GEMMs of both runs and computed some of the gpu run's on the GPU.
#
# The default input, tests/inputs/si8_smoke.in, takes seconds. An input without pseudo_dir
# reads its pseudopotentials from PSEUDO_DIR (default: deps/qe/pseudo, which has the smoke
# input's). OMP_NUM_THREADS defaults to 1. The wall times are single runs, not a benchmark.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
RESULTS_DIR="$ESPRESSIVO_ROOT/results/validate"
INPUT="$ESPRESSIVO_ROOT/tests/inputs/si8_smoke.in"
PW="$QE_DIR/build-metal/bin/pw.x"
TOL_RY="${TOL_RY:-1e-6}"

while [ $# -gt 0 ]; do
    case $1 in
        --input)   shift; INPUT="$1" ;;
        --input=*) INPUT="${1#*=}" ;;
        --pw)      shift; PW="$1" ;;
        --pw=*)    PW="${1#*=}" ;;
        *) echo "Usage: $0 [--input file.in] [--pw path/to/pw.x]"; exit 1 ;;
    esac
    shift
done

if [ ! -f "$INPUT" ]; then
    echo "ERROR: no input file $INPUT"
    exit 1
fi
INPUT="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
if [ ! -x "$PW" ]; then
    echo "ERROR: no pw.x at $PW; run ./scripts/build-qe-metal.sh first"
    exit 1
fi
if ! links_apple_bottom "$PW"; then
    echo "ERROR: $PW does not load libapplebottom.dylib"
    exit 1
fi
export ESPRESSO_PSEUDO="${PSEUDO_DIR:-$QE_DIR/pseudo}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"

echo "============================================"
echo "Espressivo: AB_MODE=cpu against AB_MODE=gpu"
echo "============================================"
echo "pw.x:  $PW"
echo "Input: $INPUT"
echo ""

# run_mode MODE: run pw.x in results/validate/MODE; keep the total energy of every SCF
# iteration and the final one (the "!" line), and the wall time.
run_mode() {
    local mode="$1" dir="$RESULTS_DIR/$1" t0
    rm -rf "$dir" && mkdir -p "$dir"
    echo "Running with AB_MODE=$mode..."
    t0=$(date +%s)
    if ! (cd "$dir" && AB_MODE="$mode" "$AB_WITH_PROFILE" "$dir/ab_profile" \
            "$PW" -in "$INPUT" > pw.out 2> pw.err); then
        echo "ERROR: pw.x failed with AB_MODE=$mode; see $dir/pw.out and $dir/pw.err"
        exit 1
    fi
    echo $(( $(date +%s) - t0 )) > "$dir/wall_seconds"
    awk '/^ *!? +total energy +=/ {print $(NF-1)}' "$dir/pw.out" > "$dir/energies"
}

# result MODE: "<final energy> <SCF iterations> <wall s> <gpu_calls> <cpu_calls>
# <gpu_time_pct> <build>", with NA for an energy or iteration count the output lacks. Fails
# if a process wrote no profile.
result() {
    local dir="$RESULTS_DIR/$1" energy iters profile
    energy=$(qe_energy "$dir/pw.out")
    iters=$(qe_iterations "$dir/pw.out")
    profile=$(python3 "$SCRIPT_DIR/ab_profile.py" "$dir/ab_profile") || return 1
    echo "${energy:-NA} ${iters:-NA} $(cat "$dir/wall_seconds") $profile"
}

run_mode cpu
run_mode gpu
R_CPU=$(result cpu)
R_GPU=$(result gpu)
read -r E_CPU IT_CPU T_CPU GC_CPU CC_CPU GP_CPU _ <<< "$R_CPU"
read -r E_GPU IT_GPU T_GPU GC_GPU CC_GPU GP_GPU BUILD_GPU <<< "$R_GPU"

FAILURES=""
fail() { FAILURES="$FAILURES  - $1"$'\n'; }
if [ "$E_CPU" = NA ] || [ "$E_GPU" = NA ] || [ "$IT_CPU" = NA ] || [ "$IT_GPU" = NA ]; then
    fail "a run did not converge"
else
    [ "$IT_CPU" = "$IT_GPU" ] || fail "SCF iterations differ: $IT_CPU (cpu), $IT_GPU (gpu)"
    DE=$(python3 -c "d = abs($E_GPU - $E_CPU); print(f'{d:.2e}'); raise SystemExit(d > $TOL_RY)") \
        || fail "final total energies differ by $DE Ry (tolerance $TOL_RY Ry)"
fi
[ $((GC_CPU + CC_CPU)) -gt 0 ] || fail "apple-bottom recorded no GEMMs: dgemm_ and zgemm_ do not reach it"
[ "$GC_GPU" -gt 0 ] || fail "the gpu run made no GPU calls"
[ "$GC_CPU" -eq 0 ] || fail "the cpu run made $GC_CPU GPU calls"
if cmp -s "$RESULTS_DIR/cpu/energies" "$RESULTS_DIR/gpu/energies"; then
    AGREEMENT="identical as printed, at all $(wc -l < "$RESULTS_DIR/cpu/energies" | tr -d ' ') values (every SCF iteration and the final one)"
else
    AGREEMENT="not identical as printed: see $RESULTS_DIR/{cpu,gpu}/energies"
fi
VERDICT=PASS
[ -z "$FAILURES" ] || VERDICT=FAIL

pct() { if [ "$1" = n/a ]; then echo n/a; else echo "$1%"; fi; }
REPORT="$RESULTS_DIR/report.txt"
{
    echo "Espressivo validation: AB_MODE=cpu against AB_MODE=gpu"
    echo "Date:         $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "Host:         $(host_desc), $(pmset -g batt | head -1 | sed -E "s/.*'(.*)'.*/\1/")"
    echo "pw.x:         $PW"
    echo "apple-bottom: $BUILD_GPU"
    echo "Input:        $INPUT"
    echo "Threads:      OMP_NUM_THREADS=$OMP_NUM_THREADS, one process"
    echo ""
    printf "%-26s %-22s %-22s\n" "" "AB_MODE=cpu" "AB_MODE=gpu"
    printf "%-26s %-22s %-22s\n" "Final total energy (Ry)" "$E_CPU" "$E_GPU"
    printf "%-26s %-22s %-22s\n" "SCF iterations" "$IT_CPU" "$IT_GPU"
    printf "%-26s %-22s %-22s\n" "GEMMs on the GPU" "$GC_CPU of $((GC_CPU + CC_CPU))" \
           "$GC_GPU of $((GC_GPU + CC_GPU))"
    printf "%-26s %-22s %-22s\n" "GPU share of GEMM time" "$(pct "$GP_CPU")" "$(pct "$GP_GPU")"
    printf "%-26s %-22s %-22s\n" "Wall time, one run (s)" "$T_CPU" "$T_GPU"
    echo ""
    echo "Total energies: $AGREEMENT"
    echo "Result: $VERDICT"
    printf "%s" "$FAILURES"
    if [ -f "$(dirname "$PW")/../PROVENANCE.txt" ]; then
        echo ""
        echo "Build provenance:"
        sed 's/^/  /' "$(dirname "$PW")/../PROVENANCE.txt"
    fi
} > "$REPORT"

cat "$REPORT"
echo ""
echo "Report: $REPORT"
echo "Runs:   $RESULTS_DIR/cpu, $RESULTS_DIR/gpu"
[ "$VERDICT" = PASS ]
