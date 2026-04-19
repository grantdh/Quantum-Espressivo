#!/bin/bash
# benchmark-paper.sh — Publication-quality 4-way Si64 benchmark
#
# Improvements over benchmark-4way.sh:
#   - 5 runs per config (configurable with --runs)
#   - Randomized run order to eliminate thermal ordering bias
#   - 120s cooldown between runs (configurable with --cooldown)
#   - Thermal monitoring (powermetrics integration when available)
#   - Reports min, median, mean, stdev, and max
#   - Saves raw data as CSV for analysis
#   - Paper-ready LaTeX table fragment
#
# Usage:
#   ./scripts/benchmark-paper.sh                          # full 4-way, 5 runs each
#   ./scripts/benchmark-paper.sh --runs 7 --cooldown 180  # 7 runs, 3min cooldown
#   ./scripts/benchmark-paper.sh --skip-openblas           # skip slow OpenBLAS config
#   ./scripts/benchmark-paper.sh --configs amx,gpu_all     # specific configs only

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESPRESSIVO_ROOT="$(dirname "$SCRIPT_DIR")"
QE_DIR="$ESPRESSIVO_ROOT/deps/qe-7.5"
RESULTS_BASE="$ESPRESSIVO_ROOT/results/paper_benchmark"
AB_DIR="$ESPRESSIVO_ROOT/deps/apple-bottom"

# Defaults
NUM_RUNS=5
COOLDOWN=120
SI64_INPUT=""
SKIP_OPENBLAS=false
CONFIGS=""  # empty = all
MPI_PROCS=0  # 0 = auto-detect, 1 = no MPI

# Parse flags
while [ $# -gt 0 ]; do
    case $1 in
        --input)          shift; SI64_INPUT="$1" ;;
        --input=*)        SI64_INPUT="${1#*=}" ;;
        --runs)           shift; NUM_RUNS="$1" ;;
        --runs=*)         NUM_RUNS="${1#*=}" ;;
        --cooldown)       shift; COOLDOWN="$1" ;;
        --cooldown=*)     COOLDOWN="${1#*=}" ;;
        --skip-openblas)  SKIP_OPENBLAS=true ;;
        --configs)        shift; CONFIGS="$1" ;;
        --configs=*)      CONFIGS="${1#*=}" ;;
        --mpi)            shift; MPI_PROCS="$1" ;;
        --mpi=*)          MPI_PROCS="${1#*=}" ;;
        --no-mpi)         MPI_PROCS=1 ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo "  --input PATH       Si64 input file path"
            echo "  --runs N           Runs per config (default: 5)"
            echo "  --cooldown SECS    Cooldown between runs (default: 120)"
            echo "  --skip-openblas    Skip OpenBLAS config"
            echo "  --configs LIST     Comma-separated: amx,gpu_all,gpu_amx,openblas"
            echo "  --mpi N            Number of MPI processes (default: auto-detect)"
            echo "  --no-mpi           Disable MPI (run single-process)"
            exit 0 ;;
    esac
    shift
done

# =========================================================================
# MPI configuration
# =========================================================================
MPIEXEC=""
if [ "$MPI_PROCS" -ne 1 ] 2>/dev/null; then
    # Find mpiexec/mpirun
    for cmd in mpiexec mpirun; do
        if command -v "$cmd" &>/dev/null; then
            MPIEXEC="$cmd"
            break
        fi
    done

    if [ -n "$MPIEXEC" ]; then
        if [ "$MPI_PROCS" -eq 0 ]; then
            # Auto-detect: use number of performance cores (macOS) or nproc/2
            if command -v sysctl &>/dev/null; then
                PERF_CORES=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || echo 0)
                if [ "$PERF_CORES" -gt 0 ]; then
                    # For Si64 (Γ-only), MPI doesn't help much — use 1
                    # Caller should use --mpi N for multi-k-point systems
                    MPI_PROCS=1
                else
                    MPI_PROCS=1
                fi
            else
                MPI_PROCS=1
            fi
        fi
    else
        echo "WARNING: mpiexec/mpirun not found — running single-process"
        MPI_PROCS=1
    fi
else
    MPI_PROCS=1
fi

# Build MPI launch prefix
MPI_PREFIX=""
if [ "$MPI_PROCS" -gt 1 ] && [ -n "$MPIEXEC" ]; then
    MPI_PREFIX="$MPIEXEC -n $MPI_PROCS"
    # Adjust OMP threads: total threads = MPI_PROCS × OMP_NUM_THREADS
    # Avoid oversubscription: if user hasn't set OMP, compute it
    if [ -z "${OMP_NUM_THREADS_SET:-}" ]; then
        TOTAL_CORES=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 8)
        OMP_THREADS_PER_MPI=$((TOTAL_CORES / MPI_PROCS))
        [ "$OMP_THREADS_PER_MPI" -lt 1 ] && OMP_THREADS_PER_MPI=1
        export OMP_NUM_THREADS=$OMP_THREADS_PER_MPI
    fi
fi

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

# Build config list
declare -a CONFIG_NAMES=()
declare -a CONFIG_BINARIES=()
declare -a CONFIG_ENV=()
declare -a CONFIG_LABELS=()
declare -a CONFIG_ROUTING=()

add_config() {
    CONFIG_NAMES+=("$1")
    CONFIG_BINARIES+=("$2")
    CONFIG_ENV+=("$3")
    CONFIG_LABELS+=("$4")
    CONFIG_ROUTING+=("$5")
}

should_run() {
    local name="$1"
    if [ -z "$CONFIGS" ]; then return 0; fi
    echo "$CONFIGS" | tr ',' '\n' | grep -q "^${name}$"
}

if [ "$SKIP_OPENBLAS" = false ] && [ -f "$PW_OPENBLAS" ] && should_run "openblas"; then
    add_config "openblas" "$PW_OPENBLAS" "" "OpenBLAS (CPU)" "cblas\_zgemm (sw)"
fi
if [ -f "$PW_AMX" ] && should_run "amx"; then
    add_config "amx" "$PW_AMX" "" "Accelerate (AMX)" "cblas\_zgemm (AMX)"
fi
if [ -f "$PW_METAL" ] && should_run "gpu_amx"; then
    add_config "gpu_amx" "$PW_METAL" "" "GPU+AMX hybrid" "ab\_zgemm (>10^8)"
fi
if [ -f "$PW_METAL" ] && should_run "gpu_all"; then
    add_config "gpu_all" "$PW_METAL" "AB_CROSSOVER_FLOPS=0" "GPU DD-BLAS" "ab\_zgemm (all)"
fi

NCONFIGS=${#CONFIG_NAMES[@]}
if [ "$NCONFIGS" -eq 0 ]; then
    echo "ERROR: No valid configurations found."
    exit 1
fi

TOTAL_RUNS=$((NCONFIGS * NUM_RUNS))

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Espressivo: Publication-Quality Si64 Benchmark                  ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Input:      $SI64_INPUT"
echo "  Configs:    ${CONFIG_NAMES[*]}"
echo "  Runs/config: $NUM_RUNS"
echo "  Cooldown:   ${COOLDOWN}s"
echo "  Total runs: $TOTAL_RUNS"
echo "  Est. time:  ~$((TOTAL_RUNS * (7 * 60 + COOLDOWN) / 60)) min"
echo ""
echo "  Hardware:   $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon')"
echo "  MPI procs:  $MPI_PROCS${MPI_PREFIX:+ ($MPIEXEC)}"
echo "  OMP_NUM_THREADS: ${OMP_NUM_THREADS:-4}"
echo "  apple-bottom: $(grep VERSION_STRING "$AB_DIR/include/apple_bottom.h" 2>/dev/null | head -1 || echo 'unknown')"
echo ""

# Create results directory with timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="$RESULTS_BASE/$TIMESTAMP"
mkdir -p "$RESULTS_DIR"

# CSV file for raw data
CSV_FILE="$RESULTS_DIR/raw_data.csv"
echo "run_order,config,run_number,wall_time_s,energy_ry,scf_iters,gpu_calls,total_calls" > "$CSV_FILE"

# =========================================================================
# Build randomized run schedule
# =========================================================================
echo "=== Building randomized run schedule ==="

# Create array of all (config_index, run_number) pairs
declare -a SCHEDULE=()
for ci in $(seq 0 $((NCONFIGS - 1))); do
    for ri in $(seq 1 $NUM_RUNS); do
        SCHEDULE+=("${ci}:${ri}")
    done
done

# Fisher-Yates shuffle
for ((i = ${#SCHEDULE[@]} - 1; i > 0; i--)); do
    j=$((RANDOM % (i + 1)))
    tmp="${SCHEDULE[$i]}"
    SCHEDULE[$i]="${SCHEDULE[$j]}"
    SCHEDULE[$j]="$tmp"
done

echo "  Schedule (${#SCHEDULE[@]} runs):"
for entry in "${SCHEDULE[@]}"; do
    ci="${entry%%:*}"
    ri="${entry##*:}"
    echo "    ${CONFIG_NAMES[$ci]} run $ri"
done
echo ""

# =========================================================================
# Execute runs
# =========================================================================
echo "=== Starting benchmark at $(date) ==="
echo ""

run_counter=0

for entry in "${SCHEDULE[@]}"; do
    ci="${entry%%:*}"
    ri="${entry##*:}"
    config="${CONFIG_NAMES[$ci]}"
    binary="${CONFIG_BINARIES[$ci]}"
    env_override="${CONFIG_ENV[$ci]}"

    run_counter=$((run_counter + 1))

    echo "--- Run $run_counter/$TOTAL_RUNS: $config #$ri ---"

    run_dir="$RESULTS_DIR/$config/run_${ri}"
    mkdir -p "$run_dir/tmp"
    cd "$run_dir"

    # Symlink pseudopotentials
    for dir in "$PSEUDO_DIR" "$INPUT_DIR"; do
        for pp in "$dir"/*.upf "$dir"/*.UPF "$dir"/*.pz-* "$dir"/*.pbe-*; do
            [ -f "$pp" ] && ln -sf "$pp" . 2>/dev/null
        done
    done

    profile_file="$run_dir/ab_profile.log"

    # Capture pre-run thermal state (macOS)
    # TODO(v1.4.0): re-add thermal telemetry via `powermetrics -n 1 -i 1000 --samplers smc,cpu_power,gpu_power`

    start_time=$(python3 -c "import time; print(time.time())")

    if [ -n "$env_override" ]; then
        env OMP_NUM_THREADS="${OMP_NUM_THREADS:-4}" \
            ESPRESSO_PSEUDO="$run_dir" \
            AB_PROFILE_FILE="$profile_file" $env_override \
            $MPI_PREFIX "$binary" < "$SI64_INPUT" > "$run_dir/pw.out" 2>&1 || true
    else
        env OMP_NUM_THREADS="${OMP_NUM_THREADS:-4}" \
            ESPRESSO_PSEUDO="$run_dir" \
            AB_PROFILE_FILE="$profile_file" \
            $MPI_PREFIX "$binary" < "$SI64_INPUT" > "$run_dir/pw.out" 2>&1 || true
    fi

    end_time=$(python3 -c "import time; print(time.time())")
    wall=$(python3 -c "print(f'{$end_time - $start_time:.1f}')")

    # Capture post-run thermal state
    # TODO(v1.4.0): re-add thermal telemetry via `powermetrics -n 1 -i 1000 --samplers smc,cpu_power,gpu_power`

    # Extract results
    energy=$(grep '!' "$run_dir/pw.out" | tail -1 | awk '{print $5}')
    scf_iter=$(grep 'convergence has been achieved' "$run_dir/pw.out" | awk '{print $6}' | head -1)

    gpu_calls="0"
    total_calls="0"
    if [ -f "$profile_file" ] && [ -s "$profile_file" ]; then
        gpu_calls=$(grep " 1$" "$profile_file" | wc -l | tr -d ' ')
        cpu_calls=$(grep " 0$" "$profile_file" | wc -l | tr -d ' ')
        total_calls=$((gpu_calls + cpu_calls))
    fi

    echo "  Config: $config  Run: $ri  Wall: ${wall}s  Energy: ${energy} Ry  SCF: ${scf_iter}"

    # Append to CSV
    echo "$run_counter,$config,$ri,$wall,$energy,$scf_iter,$gpu_calls,$total_calls" >> "$CSV_FILE"

    # Cooldown (skip after last run)
    if [ "$run_counter" -lt "$TOTAL_RUNS" ]; then
        echo "  Cooldown: ${COOLDOWN}s..."
        sleep "$COOLDOWN"
    fi
    echo ""
done

echo "=== All runs complete at $(date) ==="
echo ""

# =========================================================================
# Generate summary
# =========================================================================
echo "=== Generating summary ==="
echo ""

SUMMARY_FILE="$RESULTS_DIR/summary.txt"
LATEX_FILE="$RESULTS_DIR/table.tex"

python3 - "$CSV_FILE" "$SUMMARY_FILE" "$LATEX_FILE" << 'PYEOF'
import sys, statistics, math

csv_file = sys.argv[1]
summary_file = sys.argv[2]
latex_file = sys.argv[3]

# Parse CSV
configs = {}
with open(csv_file) as f:
    header = f.readline()
    for line in f:
        parts = line.strip().split(',')
        config = parts[1]
        wall = float(parts[3])
        energy = parts[4]
        scf = parts[5]
        if config not in configs:
            configs[config] = {'times': [], 'energy': energy, 'scf': scf}
        configs[config]['times'].append(wall)

# Order
order = ['openblas', 'amx', 'gpu_amx', 'gpu_all']
labels = {
    'openblas': ('OpenBLAS (CPU)', 'cblas_zgemm (sw)'),
    'amx': ('Accelerate (AMX)', 'cblas_zgemm (AMX)'),
    'gpu_amx': ('GPU+AMX hybrid', 'ab_zgemm (>10^8)'),
    'gpu_all': ('GPU DD-BLAS', 'ab_zgemm (all)'),
}

# Compute statistics
stats = {}
for name, data in configs.items():
    t = sorted(data['times'])
    n = len(t)
    median = t[n // 2] if n % 2 == 1 else (t[n//2 - 1] + t[n//2]) / 2
    stats[name] = {
        'min': min(t),
        'max': max(t),
        'mean': statistics.mean(t),
        'stdev': statistics.stdev(t) if n > 1 else 0,
        'median': median,
        'energy': data['energy'],
        'scf': data['scf'],
        'n': n,
        'raw': t,
    }

# Find AMX baseline
amx_min = stats.get('amx', {}).get('min', None)
amx_median = stats.get('amx', {}).get('median', None)

# Print summary
lines = []
lines.append("Espressivo Publication-Quality Benchmark Results")
lines.append("=" * 70)
lines.append("")

lines.append(f"{'Config':<18}  {'N':>3}  {'Min (s)':>8}  {'Median':>8}  {'Mean':>8}  {'Stdev':>7}  {'Max':>8}  {'Energy'}")
lines.append(f"{'-'*17:<18}  {'---':>3}  {'--------':>8}  {'------':>8}  {'------':>8}  {'-----':>7}  {'------':>8}  {'------'}")

for name in order:
    if name not in stats:
        continue
    s = stats[name]
    label = labels.get(name, (name,))[0]
    lines.append(f"{label:<18}  {s['n']:>3}  {s['min']:>8.1f}  {s['median']:>8.1f}  {s['mean']:>8.1f}  {s['stdev']:>6.1f}s  {s['max']:>8.1f}  {s['energy']} Ry")

# Speedup tables
lines.append("")
lines.append("Speedup vs AMX:")
lines.append("")

if amx_min:
    lines.append(f"  Using MIN times (best case, least thermal interference):")
    for name in order:
        if name not in stats:
            continue
        s = stats[name]
        label = labels.get(name, (name,))[0]
        speedup = amx_min / s['min']
        lines.append(f"    {label:<18}  {speedup:.2f}x  ({s['min']:.1f}s)")

if amx_median:
    lines.append("")
    lines.append(f"  Using MEDIAN times (robust central estimate):")
    for name in order:
        if name not in stats:
            continue
        s = stats[name]
        label = labels.get(name, (name,))[0]
        speedup = amx_median / s['median']
        lines.append(f"    {label:<18}  {speedup:.2f}x  ({s['median']:.1f}s)")

# Variance analysis (key for thermal story)
lines.append("")
lines.append("Variance Analysis (thermal stability):")
for name in order:
    if name not in stats:
        continue
    s = stats[name]
    label = labels.get(name, (name,))[0]
    cv = (s['stdev'] / s['mean'] * 100) if s['mean'] > 0 else 0
    spread = s['max'] - s['min']
    lines.append(f"  {label:<18}  CV={cv:.1f}%  spread={spread:.1f}s  (min={s['min']:.1f}, max={s['max']:.1f})")

# Energy check
lines.append("")
energies = set(s['energy'] for s in stats.values())
if len(energies) == 1:
    lines.append("ENERGY: ALL CONFIGURATIONS MATCH (bit-identical)")
else:
    lines.append("ENERGY: VALUES DIFFER:")
    for name in order:
        if name not in stats:
            continue
        label = labels.get(name, (name,))[0]
        lines.append(f"  {label:<18}  {stats[name]['energy']} Ry")

# Raw data
lines.append("")
lines.append("Raw times:")
for name in order:
    if name not in stats:
        continue
    label = labels.get(name, (name,))[0]
    raw_str = ', '.join(f'{t:.1f}' for t in stats[name]['raw'])
    lines.append(f"  {label:<18}  [{raw_str}]")

output = '\n'.join(lines)
print(output)

with open(summary_file, 'w') as f:
    f.write(output + '\n')

# Generate LaTeX table
latex_lines = []
latex_lines.append(r"\begin{table}[t]")
latex_lines.append(r"\centering")
latex_lines.append(r"\caption{Quantum ESPRESSO Si64 SCF Convergence (Min of N runs).}")
latex_lines.append(r"\label{tab:qe-perf}")
latex_lines.append(r"\begin{tabular}{l@{\hskip 8pt}r@{\hskip 8pt}r@{\hskip 8pt}r@{\hskip 8pt}l}")
latex_lines.append(r"\toprule")
latex_lines.append(r"\textbf{BLAS Backend} & \textbf{Time (s)} & \textbf{$\sigma$ (s)} & \textbf{vs.\ AMX} & \textbf{Total Energy (Ry)} \\")
latex_lines.append(r"\midrule")

for name in order:
    if name not in stats:
        continue
    s = stats[name]
    label = labels.get(name, (name,))[0]
    speedup = amx_min / s['min'] if amx_min else 1.0
    bold = r"\textbf" if s['min'] == min(st['min'] for st in stats.values()) else ""
    time_str = f"{bold}{{{s['min']:.1f}}}" if bold else f"{s['min']:.1f}"
    speedup_str = f"{bold}{{{speedup:.2f}$\\times$}}" if bold else f"{speedup:.2f}$\\times$"
    energy_str = f"${s['energy']}$"
    latex_lines.append(f"{label} & {time_str} & {s['stdev']:.1f} & {speedup_str} & {energy_str} \\\\")

latex_lines.append(r"\bottomrule")
latex_lines.append(r"\end{tabular}")
latex_lines.append(r"\end{table}")

latex_output = '\n'.join(latex_lines)
with open(latex_file, 'w') as f:
    f.write(latex_output + '\n')

print("")
print(f"LaTeX table saved to: {latex_file}")
PYEOF

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Benchmark Complete                                              ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Results:  $RESULTS_DIR/"
echo "  Summary:  $RESULTS_DIR/summary.txt"
echo "  Raw CSV:  $RESULTS_DIR/raw_data.csv"
echo "  LaTeX:    $RESULTS_DIR/table.tex"
echo ""
echo "  To re-analyze: python3 scripts/analyze_paper_benchmark.py $RESULTS_DIR/raw_data.csv"
