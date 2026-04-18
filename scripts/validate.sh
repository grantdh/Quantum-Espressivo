#!/bin/bash
# validate.sh — Run Si64 SCF benchmark comparing baseline vs Metal-accelerated QE
#
# Usage:
#   ./scripts/validate.sh [--input /path/to/si64.in]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESPRESSIVO_ROOT="$(dirname "$SCRIPT_DIR")"
QE_DIR="$ESPRESSIVO_ROOT/deps/qe-7.5"
RESULTS_DIR="$ESPRESSIVO_ROOT/results"

# Parse flags
SI64_INPUT=""
for arg in "$@"; do
    case $arg in
        --input) shift; SI64_INPUT="$1" ;;
        --input=*) SI64_INPUT="${arg#*=}" ;;
    esac
done

# Find or create Si64 input
if [ -z "$SI64_INPUT" ]; then
    # Check common locations
    for path in \
        "$ESPRESSIVO_ROOT/benchmarks/si64.in" \
        "$HOME/qe-test/benchmark/si64.in" \
        "$HOME/qe-test/si64.in"; do
        if [ -f "$path" ]; then
            SI64_INPUT="$path"
            break
        fi
    done
fi

if [ -z "$SI64_INPUT" ]; then
    echo "ERROR: Cannot find si64.in benchmark input."
    echo "Provide path with: ./scripts/validate.sh --input /path/to/si64.in"
    exit 1
fi

echo "============================================"
echo "Espressivo: Si64 SCF Validation"
echo "============================================"
echo "Input: $SI64_INPUT"
echo ""

mkdir -p "$RESULTS_DIR"

# Check both builds exist
BASELINE_PW="$QE_DIR/build-baseline/bin/pw.x"
METAL_PW="$QE_DIR/build-metal/bin/pw.x"

if [ ! -f "$BASELINE_PW" ]; then
    echo "ERROR: Baseline pw.x not found at $BASELINE_PW"
    echo "Run ./scripts/build-qe-metal.sh first"
    exit 1
fi

if [ ! -f "$METAL_PW" ]; then
    echo "ERROR: Metal pw.x not found at $METAL_PW"
    echo "Run ./scripts/build-qe-metal.sh first"
    exit 1
fi

# Pseudopotential directory — use the input file's directory as the source
INPUT_DIR="$(cd "$(dirname "$SI64_INPUT")" && pwd)"

# Find pseudopotentials: check input dir, then input dir/pseudo
PSEUDO_DIR="$INPUT_DIR"
if [ -d "$INPUT_DIR/pseudo" ]; then
    PSEUDO_DIR="$INPUT_DIR/pseudo"
fi
# Override if input file specifies an absolute pseudo_dir
ABS_PSEUDO=$(grep -i "pseudo_dir" "$SI64_INPUT" | grep -o "'[^']*'" | tr -d "'" | head -1)
if [ -n "$ABS_PSEUDO" ] && [ "${ABS_PSEUDO:0:1}" = "/" ]; then
    PSEUDO_DIR="$ABS_PSEUDO"
fi

PP_COUNT=$(ls "$PSEUDO_DIR"/*.upf "$PSEUDO_DIR"/*.UPF "$INPUT_DIR"/*.upf "$INPUT_DIR"/*.UPF 2>/dev/null | sort -u | wc -l | tr -d ' ')
echo "Pseudo dir: $PSEUDO_DIR ($PP_COUNT pseudopotential files found)"

if [ "$PP_COUNT" -eq 0 ]; then
    echo "WARNING: No .upf/.UPF pseudopotential files found"
    echo "QE will fail. Place pseudopotentials alongside your input file."
fi

# Run 1: Baseline (CPU only)
echo ""
echo "--- Running Baseline (CPU BLAS) ---"
WORK_DIR="$RESULTS_DIR/baseline_run"
rm -rf "$WORK_DIR" && mkdir -p "$WORK_DIR/tmp"

cd "$WORK_DIR"

# Symlink pseudopotentials into the working directory
# Search both PSEUDO_DIR and INPUT_DIR (they may differ)
for dir in "$PSEUDO_DIR" "$INPUT_DIR"; do
    for pp in "$dir"/*.upf "$dir"/*.UPF "$dir"/*.pz-* "$dir"/*.pbe-*; do
        [ -f "$pp" ] && ln -sf "$pp" . 2>/dev/null
    done
done

export OMP_NUM_THREADS=4

echo "Starting baseline run..."
START_TIME=$(python3 -c "import time; print(time.time())")
"$BASELINE_PW" < "$SI64_INPUT" > baseline.out 2>&1 || true
END_TIME=$(python3 -c "import time; print(time.time())")
BASELINE_WALL=$(python3 -c "print(f'{$END_TIME - $START_TIME:.1f}')")

BASELINE_ENERGY=$(grep '!' baseline.out | tail -1 | awk '{print $5}')
BASELINE_SCF=$(grep 'convergence has been achieved' baseline.out | awk '{print $6}' | head -1)

echo "  Wall time:    ${BASELINE_WALL}s"
echo "  Total energy: ${BASELINE_ENERGY} Ry"
echo "  SCF iters:    ${BASELINE_SCF}"

# Run 2: Metal-accelerated
echo ""
echo "--- Running Metal-Accelerated ---"
WORK_DIR="$RESULTS_DIR/metal_run"
rm -rf "$WORK_DIR" && mkdir -p "$WORK_DIR/tmp"

cd "$WORK_DIR"

# Symlink pseudopotentials into the working directory
# Search both PSEUDO_DIR and INPUT_DIR (they may differ)
for dir in "$PSEUDO_DIR" "$INPUT_DIR"; do
    for pp in "$dir"/*.upf "$dir"/*.UPF "$dir"/*.pz-* "$dir"/*.pbe-*; do
        [ -f "$pp" ] && ln -sf "$pp" . 2>/dev/null
    done
done

export AB_PROFILE_FILE="$WORK_DIR/ab_profile.log"

echo "Starting Metal run..."
START_TIME=$(python3 -c "import time; print(time.time())")
"$METAL_PW" < "$SI64_INPUT" > metal.out 2>&1 || true
END_TIME=$(python3 -c "import time; print(time.time())")
METAL_WALL=$(python3 -c "print(f'{$END_TIME - $START_TIME:.1f}')")

METAL_ENERGY=$(grep '!' metal.out | tail -1 | awk '{print $5}')
METAL_SCF=$(grep 'convergence has been achieved' metal.out | awk '{print $6}' | head -1)

# Parse profiling data
if [ -f "$WORK_DIR/ab_profile.log" ]; then
    GPU_CALLS=$(grep " 1$" "$WORK_DIR/ab_profile.log" | wc -l | tr -d ' ')
    CPU_CALLS=$(grep " 0$" "$WORK_DIR/ab_profile.log" | wc -l | tr -d ' ')
    TOTAL_CALLS=$((GPU_CALLS + CPU_CALLS))
else
    GPU_CALLS="N/A"
    CPU_CALLS="N/A"
    TOTAL_CALLS="N/A"
fi

echo "  Wall time:    ${METAL_WALL}s"
echo "  Total energy: ${METAL_ENERGY} Ry"
echo "  SCF iters:    ${METAL_SCF}"
echo "  GPU calls:    ${GPU_CALLS}/${TOTAL_CALLS}"

# Summary
echo ""
echo "============================================"
echo "RESULTS COMPARISON"
echo "============================================"
echo ""
printf "%-20s %-20s %-20s\n" "Metric" "Baseline (CPU)" "Metal (GPU)"
printf "%-20s %-20s %-20s\n" "----" "----" "----"
printf "%-20s %-20s %-20s\n" "Wall time" "${BASELINE_WALL}s" "${METAL_WALL}s"
printf "%-20s %-20s %-20s\n" "Total energy" "${BASELINE_ENERGY} Ry" "${METAL_ENERGY} Ry"
printf "%-20s %-20s %-20s\n" "SCF iterations" "${BASELINE_SCF}" "${METAL_SCF}"
printf "%-20s %-20s %-20s\n" "GPU/CPU routing" "N/A" "${GPU_CALLS}/${TOTAL_CALLS}"

# Compute speedup
if [ -n "$BASELINE_WALL" ] && [ -n "$METAL_WALL" ]; then
    SPEEDUP=$(python3 -c "print(f'{$BASELINE_WALL / $METAL_WALL:.2f}')")
    echo ""
    echo "Speedup: ${SPEEDUP}x"
fi

# Check energy agreement
if [ -n "$BASELINE_ENERGY" ] && [ -n "$METAL_ENERGY" ]; then
    echo ""
    if [ "$BASELINE_ENERGY" = "$METAL_ENERGY" ]; then
        echo "ENERGY: EXACT MATCH"
    else
        echo "ENERGY: Check agreement manually (may differ in last digits)"
    fi
fi

# Save results
REPORT="$RESULTS_DIR/validation_report.txt"
{
    echo "Espressivo Validation Report"
    echo "Date: $(date)"
    echo "QE Version: 7.5 (developer branch)"
    echo "apple-bottom: $(grep VERSION_STRING $ESPRESSIVO_ROOT/deps/apple-bottom/include/apple_bottom.h 2>/dev/null | head -1 || echo 'unknown')"
    echo ""
    echo "Baseline: ${BASELINE_WALL}s, E=${BASELINE_ENERGY} Ry, ${BASELINE_SCF} SCF iters"
    echo "Metal:    ${METAL_WALL}s, E=${METAL_ENERGY} Ry, ${METAL_SCF} SCF iters"
    echo "Speedup:  ${SPEEDUP}x"
    echo "GPU routing: ${GPU_CALLS}/${TOTAL_CALLS} calls"
} > "$REPORT"

echo ""
echo "Report saved to: $REPORT"
echo "Detailed output: $RESULTS_DIR/baseline_run/baseline.out"
echo "                 $RESULTS_DIR/metal_run/metal.out"
echo "Profiling log:   $RESULTS_DIR/metal_run/ab_profile.log"
