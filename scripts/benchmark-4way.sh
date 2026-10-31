#!/bin/bash
# benchmark-4way.sh — 4-way Si64 SCF wall-clock comparison
#
# Configurations:
#   1. OpenBLAS (CPU)   — pure software FP64, no AMX, no GPU
#   2. Accelerate (AMX) — Apple AMX hardware BLAS
#   3. auto             — the apple-bottom build with AB_MODE=auto
#   4. gpu              — the apple-bottom build with AB_MODE=gpu
#
# Usage:
#   ./scripts/benchmark-4way.sh [--input /path/to/si64.in] [--runs N] [--skip-openblas]
#
# Output:
#   results/benchmark_4way/summary.txt       — summary table
#   results/benchmark_4way/<config>/run_N/    — individual run outputs + apple-bottom profiles

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
RESULTS_BASE="$ESPRESSIVO_ROOT/results/benchmark_4way"

# Defaults
NUM_RUNS=3
SI64_INPUT=""
SKIP_OPENBLAS=false

# Parse flags
while [ $# -gt 0 ]; do
    case $1 in
        --input)    shift; SI64_INPUT="$1" ;;
        --input=*)  SI64_INPUT="${1#*=}" ;;
        --runs)     shift; NUM_RUNS="$1" ;;
        --runs=*)   NUM_RUNS="${1#*=}" ;;
        --skip-openblas) SKIP_OPENBLAS=true ;;
    esac
    shift
done

# Find Si64 input
if [ -z "$SI64_INPUT" ]; then
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
    echo "ERROR: Cannot find si64.in. Provide with --input /path/to/si64.in"
    exit 1
fi

INPUT_DIR="$(cd "$(dirname "$SI64_INPUT")" && pwd)"

# Pseudopotential directory
PSEUDO_DIR="$INPUT_DIR"
if [ -d "$INPUT_DIR/pseudo" ]; then
    PSEUDO_DIR="$INPUT_DIR/pseudo"
fi
ABS_PSEUDO=$(grep -i "pseudo_dir" "$SI64_INPUT" | grep -o "'[^']*'" | tr -d "'" | head -1)
if [ -n "$ABS_PSEUDO" ] && [ "${ABS_PSEUDO:0:1}" = "/" ]; then
    PSEUDO_DIR="$ABS_PSEUDO"
fi

# Locate binaries
PW_OPENBLAS="$QE_DIR/build-openblas/bin/pw.x"
PW_AMX="$QE_DIR/build-baseline/bin/pw.x"
PW_METAL="$QE_DIR/build-metal/bin/pw.x"

echo "============================================"
echo "Espressivo: 4-Way Si64 SCF Benchmark"
echo "============================================"
echo "Input:      $SI64_INPUT"
echo "Pseudo dir: $PSEUDO_DIR"
echo "Runs/config: $NUM_RUNS"
echo ""

# Track which configs are available (bash 3.2 compatible)
RUN_OPENBLAS=false
RUN_AMX=false
RUN_AUTO=false
RUN_GPU=false

if [ "$SKIP_OPENBLAS" = false ] && [ -f "$PW_OPENBLAS" ]; then
    RUN_OPENBLAS=true
    echo "  [x] OpenBLAS:  $PW_OPENBLAS"
elif [ "$SKIP_OPENBLAS" = false ]; then
    echo "  [ ] OpenBLAS:  NOT FOUND — run ./scripts/build-qe-openblas.sh or use --skip-openblas"
else
    echo "  [-] OpenBLAS:  SKIPPED"
fi

if [ -f "$PW_AMX" ]; then
    RUN_AMX=true
    echo "  [x] AMX:       $PW_AMX"
else
    echo "  [ ] AMX:       NOT FOUND"
fi

if [ -f "$PW_METAL" ]; then
    RUN_AUTO=true
    RUN_GPU=true
    echo "  [x] auto:      $PW_METAL (AB_MODE=auto)"
    echo "  [x] gpu:       $PW_METAL (AB_MODE=gpu)"
else
    echo "  [ ] auto:      NOT FOUND"
    echo "  [ ] gpu:       NOT FOUND"
fi

HAS_ANY=false
if $RUN_OPENBLAS || $RUN_AMX || $RUN_AUTO || $RUN_GPU; then
    HAS_ANY=true
fi

if [ "$HAS_ANY" = false ]; then
    echo ""
    echo "ERROR: No QE binaries found. Build first."
    exit 1
fi

echo ""
echo "Starting benchmark at $(date)"
echo ""

mkdir -p "$RESULTS_BASE"

# =========================================================================
# run_config CONFIG_NAME PW_BINARY [ENV_VAR=VALUE]
# Runs NUM_RUNS iterations, collects wall time, energy, SCF iters, profiles
# =========================================================================
run_config() {
    local config_name="$1"
    local pw_binary="$2"
    local env_override="$3"

    echo "=== Configuration: $config_name ==="
    echo "    Binary: $pw_binary"
    [ -n "$env_override" ] && echo "    Env:    $env_override"

    local config_dir="$RESULTS_BASE/$config_name"
    mkdir -p "$config_dir"

    local all_times=""
    local last_energy=""
    local last_scf=""

    for run in $(seq 1 $NUM_RUNS); do
        local run_dir="$config_dir/run_${run}"
        rm -rf "$run_dir" && mkdir -p "$run_dir/tmp"
        cd "$run_dir"

        # Symlink pseudopotentials
        for dir in "$PSEUDO_DIR" "$INPUT_DIR"; do
            for pp in "$dir"/*.upf "$dir"/*.UPF "$dir"/*.pz-* "$dir"/*.pbe-*; do
                [ -f "$pp" ] && ln -sf "$pp" . 2>/dev/null
            done
        done

        export OMP_NUM_THREADS=4

        echo "    Run $run/$NUM_RUNS..."
        local start_time=$(python3 -c "import time; print(time.time())")

        # Execute with optional env override; apple-bottom builds write their profile
        env $env_override "$AB_WITH_PROFILE" "$run_dir/ab_profile" \
            "$pw_binary" < "$SI64_INPUT" > "$run_dir/pw.out" 2>&1 || true

        local end_time=$(python3 -c "import time; print(time.time())")
        local wall=$(python3 -c "print(f'{$end_time - $start_time:.1f}')")

        # Extract results
        local energy=$(qe_energy "$run_dir/pw.out")
        local scf_iter=$(qe_iterations "$run_dir/pw.out")

        # GPU routing stats (NA for builds without apple-bottom, or if the profile is missing)
        local gpu_calls=NA cpu_calls=NA gpu_pct=NA ab_build=NA
        if links_apple_bottom "$pw_binary"; then
            read -r gpu_calls cpu_calls gpu_pct ab_build <<< "$(ab_summary "$run_dir/ab_profile")"
            [ "$ab_build" = NA ] || AB_BUILD="$ab_build"
        fi

        # Accumulate times (space-separated)
        if [ -z "$all_times" ]; then
            all_times="$wall"
        else
            all_times="$all_times $wall"
        fi
        last_energy="$energy"
        last_scf="$scf_iter"

        echo "      Wall: ${wall}s  Energy: ${energy} Ry  SCF: ${scf_iter}  GPU calls: ${gpu_calls} (CPU: ${cpu_calls})  GPU time: ${gpu_pct}%"

        # Save per-run summary
        {
            echo "config=$config_name run=$run"
            echo "wall_time=$wall"
            echo "total_energy=$energy"
            echo "scf_iterations=$scf_iter"
            ab_kv "$gpu_calls" "$cpu_calls" "$gpu_pct" "$ab_build"
        } > "$run_dir/summary.txt"
    done

    # Compute statistics
    local stats=$(python3 -c "
import statistics
times = [$( echo "$all_times" | tr ' ' ',' )]
mean = statistics.mean(times)
stdev = statistics.stdev(times) if len(times) > 1 else 0.0
print(f'{mean:.1f} {stdev:.1f} {min(times):.1f} {max(times):.1f}')
")
    local mean_time=$(echo $stats | awk '{print $1}')
    local stdev_time=$(echo $stats | awk '{print $2}')
    local min_time=$(echo $stats | awk '{print $3}')
    local max_time=$(echo $stats | awk '{print $4}')

    # Write config summary
    {
        echo "Configuration: $config_name"
        echo "Runs: $NUM_RUNS"
        echo "Wall time: ${mean_time} +/- ${stdev_time} s (min=${min_time}, max=${max_time})"
        echo "Energy: ${last_energy} Ry"
        echo "SCF iterations: ${last_scf}"
        echo "Raw times: ${all_times}"
    } > "$config_dir/stats.txt"

    # Append to raw results for summary table (include min_time)
    echo "$config_name $mean_time $stdev_time $min_time $last_energy $last_scf" >> "$RESULTS_BASE/_raw_results.tmp"

    echo ""
}

# Clean temp file
rm -f "$RESULTS_BASE/_raw_results.tmp"
AB_BUILD=NA  # set by run_config from the apple-bottom profiles

# =========================================================================
# Run all configurations
# =========================================================================

# Cooldown between configs to reduce thermal throttling effects
cooldown() {
    echo "--- Cooldown: 60s thermal recovery ---"
    sleep 60
    echo "    Resuming."
    echo ""
}

# 1. OpenBLAS (pure CPU, no AMX)
if [ "$RUN_OPENBLAS" = true ]; then
    run_config "openblas" "$PW_OPENBLAS" ""
    cooldown
fi

# 2. Accelerate (AMX)
if [ "$RUN_AMX" = true ]; then
    run_config "amx" "$PW_AMX" ""
    cooldown
fi

# 3. apple-bottom, calibrated routing
if [ "$RUN_AUTO" = true ]; then
    run_config "auto" "$PW_METAL" "AB_MODE=auto"
    cooldown
fi

# 4. apple-bottom, every GEMM above AB_MIN_GPU_DIM on the GPU
if [ "$RUN_GPU" = true ]; then
    run_config "gpu" "$PW_METAL" "AB_MODE=gpu"
fi

# =========================================================================
# Generate summary table
# =========================================================================
echo "============================================"
echo "SUMMARY TABLE"
echo "============================================"
echo ""

SUMMARY_FILE="$RESULTS_BASE/summary.txt"

# Header
{
    echo "Espressivo 4-Way Benchmark Results"
    echo "Date: $(date)"
    echo "Input: $SI64_INPUT"
    echo "Runs per config: $NUM_RUNS"
    echo "OMP_NUM_THREADS: 4"
    echo "apple-bottom: $AB_BUILD"
    echo "Hardware: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon')"
    echo ""
    printf "%-16s  %-20s  %-22s  %-8s  %-14s\n" "Configuration" "GEMM routing" "Wall time (s)" "SCF" "Total energy"
    printf "%-16s  %-20s  %-22s  %-8s  %-14s\n" "---------------" "-------------------" "---------------------" "-------" "-------------"
} | tee "$SUMMARY_FILE"

# Generate results using python for reliable formatting (no subshell variable issues)
if [ -f "$RESULTS_BASE/_raw_results.tmp" ]; then
    python3 - "$RESULTS_BASE/_raw_results.tmp" "$SUMMARY_FILE" << 'PYEOF'
import sys

raw_file = sys.argv[1]
summary_file = sys.argv[2]

configs = []
with open(raw_file) as f:
    for line in f:
        parts = line.strip().split()
        # config mean stdev min energy scf
        configs.append({
            'name': parts[0],
            'mean': float(parts[1]),
            'stdev': float(parts[2]),
            'min': float(parts[3]),
            'energy': parts[4],
            'scf': parts[5],
        })

labels = {
    'openblas': ('OpenBLAS (CPU)', 'cblas_zgemm (sw)'),
    'amx': ('Accelerate (AMX)', 'cblas_zgemm (AMX)'),
    'auto': ('apple-bottom auto', 'AB_MODE=auto'),
    'gpu': ('apple-bottom gpu', 'AB_MODE=gpu'),
}

lines = []

# Table header
lines.append(f"{'Configuration':<18}  {'GEMM routing':<20}  {'Mean (s)':>10}  {'Stdev':>8}  {'Min (s)':>10}  {'SCF':>4}  {'Total energy'}")
lines.append(f"{'-'*17:<18}  {'-'*19:<20}  {'-'*10:>10}  {'-'*8:>8}  {'-'*10:>10}  {'-'*4:>4}  {'-'*20}")

for c in configs:
    label, routing = labels.get(c['name'], (c['name'], '?'))
    lines.append(f"{label:<18}  {routing:<20}  {c['mean']:>10.1f}  {c['stdev']:>7.1f}s  {c['min']:>10.1f}  {c['scf']:>4}  {c['energy']} Ry")

# Speedup section (using min times — most representative under thermal variation)
amx_min = None
for c in configs:
    if c['name'] == 'amx':
        amx_min = c['min']
        break

lines.append("")
if amx_min:
    lines.append(f"Speedup vs AMX (using min times — least thermal interference):")
    for c in configs:
        label = labels.get(c['name'], (c['name'],))[0]
        speedup = amx_min / c['min']
        lines.append(f"  {label:<18}  {speedup:.2f}x")

# Energy check
lines.append("")
energies = set(c['energy'] for c in configs)
if len(energies) == 1:
    lines.append("ENERGY: ALL CONFIGURATIONS MATCH")
else:
    lines.append("ENERGY: CHECK AGREEMENT — values differ:")
    for c in configs:
        label = labels.get(c['name'], (c['name'],))[0]
        lines.append(f"  {label:<18}  {c['energy']} Ry")

output = '\n'.join(lines)
print(output)

# Append to summary file
with open(summary_file, 'a') as f:
    f.write(output + '\n')
PYEOF
fi

rm -f "$RESULTS_BASE/_raw_results.tmp"

echo ""
echo "============================================"
echo "Results saved to: $SUMMARY_FILE"
echo "Per-config details: $RESULTS_BASE/<config>/stats.txt"
echo "Individual runs:    $RESULTS_BASE/<config>/run_N/"
echo "============================================"
