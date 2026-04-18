#!/bin/bash
# calibrate-omp.sh — Find optimal OMP_NUM_THREADS for each QE config
#
# Runs a short QE calculation (2 SCF steps) at each thread count from 1..max
# and reports wall times. This tells you exactly where the sweet spot is
# instead of guessing.
#
# On Apple Silicon, more threads ≠ faster because:
#   - No thread affinity: OS scheduler may put OMP threads on E-cores
#   - AMX is per-cluster: threads on different clusters share different AMX units
#   - OpenMP barriers can trigger QoS demotion (threads yield → E-core migration)
#   - L2 cache is per-cluster: too many threads can thrash cache
#
# Usage:
#   ./scripts/calibrate-omp.sh                    # sweep 1..P-cores for Si64
#   ./scripts/calibrate-omp.sh --max-threads 12   # include E-cores in sweep
#   ./scripts/calibrate-omp.sh --system ausurf    # calibrate AUSURF instead
#   ./scripts/calibrate-omp.sh --configs amx,gpu_amx  # specific configs only
#   ./scripts/calibrate-omp.sh --mpi 4            # calibrate with MPI
#   ./scripts/calibrate-omp.sh --cooldown 60      # shorter cooldown

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESPRESSIVO_ROOT="$(dirname "$SCRIPT_DIR")"
QE_DIR="$ESPRESSIVO_ROOT/deps/qe-7.5"
AB_DIR="$ESPRESSIVO_ROOT/deps/apple-bottom"

# Defaults
MAX_THREADS=0  # 0 = auto (P-cores only)
COOLDOWN=90
SYSTEM="si64"
CONFIGS="amx,gpu_amx"
MPI_PROCS=1
REPS=2  # runs per (config, thread_count) pair

while [ $# -gt 0 ]; do
    case $1 in
        --max-threads)  shift; MAX_THREADS="$1" ;;
        --max-threads=*) MAX_THREADS="${1#*=}" ;;
        --cooldown)     shift; COOLDOWN="$1" ;;
        --cooldown=*)   COOLDOWN="${1#*=}" ;;
        --system)       shift; SYSTEM="$1" ;;
        --system=*)     SYSTEM="${1#*=}" ;;
        --configs)      shift; CONFIGS="$1" ;;
        --configs=*)    CONFIGS="${1#*=}" ;;
        --mpi)          shift; MPI_PROCS="$1" ;;
        --mpi=*)        MPI_PROCS="${1#*=}" ;;
        --reps)         shift; REPS="$1" ;;
        --reps=*)       REPS="${1#*=}" ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo "  --max-threads N   Max OMP threads to test (default: P-core count)"
            echo "  --cooldown SECS   Cooldown between runs (default: 90)"
            echo "  --system NAME     si64 or ausurf (default: si64)"
            echo "  --configs LIST    Configs to test (default: amx,gpu_amx)"
            echo "  --mpi N           MPI processes (default: 1)"
            echo "  --reps N          Repetitions per point (default: 2)"
            exit 0 ;;
    esac
    shift
done

# =========================================================================
# Detect hardware
# =========================================================================
PERF_CORES=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || echo 0)
EFF_CORES=$(sysctl -n hw.perflevel1.logicalcpu 2>/dev/null || echo 0)
TOTAL_CORES=$((PERF_CORES + EFF_CORES))

if [ "$PERF_CORES" -eq 0 ]; then
    PERF_CORES=$(nproc 2>/dev/null || echo 4)
    EFF_CORES=0
    TOTAL_CORES=$PERF_CORES
fi

if [ "$MAX_THREADS" -eq 0 ]; then
    MAX_THREADS=$PERF_CORES
fi

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  OMP_NUM_THREADS Calibration                                     ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Hardware:     $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Unknown')"
echo "  P-cores:      $PERF_CORES"
echo "  E-cores:      $EFF_CORES"
echo "  Total:        $TOTAL_CORES"
echo "  Sweep:        1..$MAX_THREADS threads"
echo "  System:       $SYSTEM"
echo "  Configs:      $CONFIGS"
echo "  MPI procs:    $MPI_PROCS"
echo "  Reps/point:   $REPS"
echo "  Cooldown:     ${COOLDOWN}s"
echo ""

# =========================================================================
# Find input and binaries
# =========================================================================
case "$SYSTEM" in
    si64)
        INPUT=""
        for path in \
            "$ESPRESSIVO_ROOT/benchmarks/si64.in" \
            "$HOME/qe-test/benchmark/si64.in" \
            "$HOME/qe-test/si64.in"; do
            [ -f "$path" ] && INPUT="$path" && break
        done
        ;;
    ausurf)
        INPUT="$QE_DIR/test-suite/benchmarks/pw/ausurf.in"
        ;;
esac

if [ -z "$INPUT" ] || [ ! -f "$INPUT" ]; then
    echo "ERROR: Input file not found for system=$SYSTEM"
    exit 1
fi

INPUT_DIR="$(cd "$(dirname "$INPUT")" && pwd)"
echo "  Input: $INPUT"

PW_AMX="$QE_DIR/build-baseline/bin/pw.x"
PW_METAL="$QE_DIR/build-metal/bin/pw.x"

# MPI prefix
MPIEXEC=""
MPI_PREFIX=""
if [ "$MPI_PROCS" -gt 1 ]; then
    for cmd in mpiexec mpirun; do
        command -v "$cmd" &>/dev/null && MPIEXEC="$cmd" && break
    done
    if [ -n "$MPIEXEC" ]; then
        MPI_PREFIX="$MPIEXEC -n $MPI_PROCS"
        echo "  MPI: $MPI_PREFIX"
    else
        echo "  WARNING: mpiexec not found, running single-process"
        MPI_PROCS=1
    fi
fi
echo ""

# =========================================================================
# Prepare results
# =========================================================================
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="$ESPRESSIVO_ROOT/results/omp_calibration/$TIMESTAMP"
mkdir -p "$RESULTS_DIR"
CSV="$RESULTS_DIR/calibration.csv"
echo "config,omp_threads,mpi_procs,rep,wall_time_s,energy_ry,scf_iters" > "$CSV"

# =========================================================================
# Build run schedule — randomized to eliminate ordering bias
# =========================================================================
declare -a SCHEDULE=()

for config in $(echo "$CONFIGS" | tr ',' ' '); do
    for threads in $(seq 1 $MAX_THREADS); do
        for rep in $(seq 1 $REPS); do
            SCHEDULE+=("${config}:${threads}:${rep}")
        done
    done
done

# Fisher-Yates shuffle
for ((i = ${#SCHEDULE[@]} - 1; i > 0; i--)); do
    j=$((RANDOM % (i + 1)))
    tmp="${SCHEDULE[$i]}"
    SCHEDULE[$i]="${SCHEDULE[$j]}"
    SCHEDULE[$j]="$tmp"
done

TOTAL=${#SCHEDULE[@]}
EST_MINS=$(( TOTAL * (5 * 60 + COOLDOWN) / 60 ))
echo "=== Schedule: $TOTAL runs (est. ~${EST_MINS} min) ==="
echo ""

# =========================================================================
# Execute
# =========================================================================
counter=0
for entry in "${SCHEDULE[@]}"; do
    IFS=':' read -r config threads rep <<< "$entry"
    counter=$((counter + 1))

    # Select binary and env
    case "$config" in
        amx)     binary="$PW_AMX"; env_override="" ;;
        gpu_all) binary="$PW_METAL"; env_override="AB_CROSSOVER_FLOPS=0" ;;
        gpu_amx) binary="$PW_METAL"; env_override="" ;;
        *)       echo "  SKIP: unknown config $config"; continue ;;
    esac

    if [ ! -f "$binary" ]; then
        echo "  SKIP: $binary not found"
        continue
    fi

    echo "--- Run $counter/$TOTAL: $config OMP=$threads rep=$rep ---"

    run_dir="$RESULTS_DIR/${config}/omp${threads}/rep${rep}"
    mkdir -p "$run_dir/tmp"
    cd "$run_dir"

    # Symlink pseudopotentials
    for dir in "$INPUT_DIR" "$HOME/qe-test/benchmark"; do
        for pp in "$dir"/*.upf "$dir"/*.UPF "$dir"/*.pz-* "$dir"/*.pbe-*; do
            [ -f "$pp" ] && ln -sf "$pp" . 2>/dev/null
        done
    done

    start_time=$(python3 -c "import time; print(time.time())")

    if [ -n "$env_override" ]; then
        env OMP_NUM_THREADS="$threads" \
            ESPRESSO_PSEUDO="$run_dir" \
            $env_override \
            $MPI_PREFIX "$binary" < "$INPUT" > "$run_dir/pw.out" 2>&1 || true
    else
        env OMP_NUM_THREADS="$threads" \
            ESPRESSO_PSEUDO="$run_dir" \
            $MPI_PREFIX "$binary" < "$INPUT" > "$run_dir/pw.out" 2>&1 || true
    fi

    end_time=$(python3 -c "import time; print(time.time())")
    wall=$(python3 -c "print(f'{$end_time - $start_time:.1f}')")

    energy=$(grep '!' "$run_dir/pw.out" | tail -1 | awk '{print $5}')
    scf_iter=$(grep 'convergence has been achieved' "$run_dir/pw.out" | awk '{print $6}' | head -1)

    echo "  $config | OMP=$threads | rep=$rep | ${wall}s | E=$energy"
    echo "$config,$threads,$MPI_PROCS,$rep,$wall,$energy,$scf_iter" >> "$CSV"

    if [ "$counter" -lt "$TOTAL" ]; then
        echo "  Cooldown: ${COOLDOWN}s..."
        sleep "$COOLDOWN"
    fi
    echo ""
done

echo "=== Calibration complete at $(date) ==="
echo ""

# =========================================================================
# Analyze results
# =========================================================================
python3 - "$CSV" "$RESULTS_DIR" "$PERF_CORES" "$EFF_CORES" << 'PYEOF'
import sys, statistics

csv_file = sys.argv[1]
results_dir = sys.argv[2]
p_cores = int(sys.argv[3])
e_cores = int(sys.argv[4])

# Parse CSV
data = {}
with open(csv_file) as f:
    header = f.readline()
    for line in f:
        parts = line.strip().split(',')
        if len(parts) < 5:
            continue
        config, threads, mpi, rep, wall = parts[0], int(parts[1]), int(parts[2]), int(parts[3]), parts[4]
        try:
            wall = float(wall)
        except ValueError:
            continue
        key = (config, threads)
        if key not in data:
            data[key] = []
        data[key].append(wall)

# Analyze per config
configs = sorted(set(k[0] for k in data))
thread_counts = sorted(set(k[1] for k in data))

lines = []
lines.append("OMP_NUM_THREADS Calibration Results")
lines.append("=" * 70)
lines.append(f"Hardware: {p_cores} P-cores + {e_cores} E-cores")
lines.append("")

for config in configs:
    lines.append(f"\n{'='*50}")
    lines.append(f"Config: {config}")
    lines.append(f"{'='*50}")
    lines.append("")
    lines.append(f"  {'Threads':>7}  {'Min (s)':>8}  {'Mean (s)':>8}  {'Max (s)':>8}  {'Speedup':>8}  {'Note'}")
    lines.append(f"  {'-------':>7}  {'-------':>8}  {'-------':>8}  {'-------':>8}  {'-------':>8}  {'----'}")

    # Find baseline (1 thread)
    baseline_min = None
    best_min = float('inf')
    best_threads = 1

    results = {}
    for threads in thread_counts:
        key = (config, threads)
        if key not in data:
            continue
        times = data[key]
        t_min = min(times)
        t_mean = statistics.mean(times)
        t_max = max(times)
        results[threads] = (t_min, t_mean, t_max)
        if threads == 1:
            baseline_min = t_min
        if t_min < best_min:
            best_min = t_min
            best_threads = threads

    for threads in thread_counts:
        if threads not in results:
            continue
        t_min, t_mean, t_max = results[threads]
        speedup = baseline_min / t_min if baseline_min else 1.0
        note = ""
        if threads == best_threads:
            note = "<-- OPTIMAL"
        elif threads == p_cores:
            note = "(P-core count)"
        elif threads > p_cores:
            note = "(includes E-cores)"
        lines.append(f"  {threads:>7}  {t_min:>8.1f}  {t_mean:>8.1f}  {t_max:>8.1f}  {speedup:>7.2f}x  {note}")

    lines.append("")
    lines.append(f"  >>> RECOMMENDED: OMP_NUM_THREADS={best_threads} ({best_min:.1f}s)")

lines.append("")
lines.append("=" * 70)
lines.append("Recommended .env:")
lines.append("")
for config in configs:
    best_t = 1
    best_min = float('inf')
    for threads in thread_counts:
        key = (config, threads)
        if key in data and min(data[key]) < best_min:
            best_min = min(data[key])
            best_t = threads
    lines.append(f"  {config}: OMP_NUM_THREADS={best_t}")

output = '\n'.join(lines)
print(output)

with open(f"{results_dir}/analysis.txt", 'w') as f:
    f.write(output + '\n')

print(f"\nSaved to: {results_dir}/analysis.txt")
PYEOF

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Calibration Complete                                            ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Results: $RESULTS_DIR/"
echo "  CSV:     $CSV"
echo "  Analysis: $RESULTS_DIR/analysis.txt"
echo ""
echo "  Use these values in benchmark scripts:"
echo "    OMP_NUM_THREADS=<optimal> ./scripts/benchmark-overnight.sh"
