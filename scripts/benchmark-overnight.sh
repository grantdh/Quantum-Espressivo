#!/bin/bash
# benchmark-overnight.sh — Run multi-system DFT benchmarks overnight
#
# Systems:
#   1. Si64    (64 atoms, Γ-only, ~18K PWs, ~150 bands) — baseline, ~7 min/run
#   2. AUSURF112 (112 atoms, 4 k-pts, 800 bands) — medium, ~30-60 min/run
#
# Each system is run with:
#   - Accelerate (AMX) baseline
#   - GPU DD-BLAS (all ZGEMM to GPU)
#   - GPU+AMX hybrid (threshold routing)
#
# Total estimated time: ~6-8 hours
#
# Usage:
#   ./scripts/benchmark-overnight.sh                    # all systems
#   ./scripts/benchmark-overnight.sh --systems si64     # si64 only
#   ./scripts/benchmark-overnight.sh --systems ausurf   # ausurf only
#   ./scripts/benchmark-overnight.sh --runs 3           # 3 runs per config (default: 3)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESPRESSIVO_ROOT="$(dirname "$SCRIPT_DIR")"
QE_DIR="$ESPRESSIVO_ROOT/deps/qe-7.5"
RESULTS_BASE="$ESPRESSIVO_ROOT/results/overnight"
AB_DIR="$ESPRESSIVO_ROOT/deps/apple-bottom"

# Defaults
NUM_RUNS=3
COOLDOWN=180  # 3 min between runs (longer for thermal recovery on big jobs)
SYSTEMS="si64,ausurf"
CONFIGS="amx,gpu_all,gpu_amx"
MPI_PROCS=0  # 0 = auto-detect per system, 1 = no MPI

# Parse flags
while [ $# -gt 0 ]; do
    case $1 in
        --systems)    shift; SYSTEMS="$1" ;;
        --systems=*)  SYSTEMS="${1#*=}" ;;
        --runs)       shift; NUM_RUNS="$1" ;;
        --runs=*)     NUM_RUNS="${1#*=}" ;;
        --cooldown)   shift; COOLDOWN="$1" ;;
        --cooldown=*) COOLDOWN="${1#*=}" ;;
        --configs)    shift; CONFIGS="$1" ;;
        --configs=*)  CONFIGS="${1#*=}" ;;
        --mpi)        shift; MPI_PROCS="$1" ;;
        --mpi=*)      MPI_PROCS="${1#*=}" ;;
        --no-mpi)     MPI_PROCS=1 ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo "  --systems LIST   Comma-separated: si64,ausurf (default: both)"
            echo "  --configs LIST   Comma-separated: amx,gpu_all,gpu_amx (default: all)"
            echo "  --runs N         Runs per config per system (default: 3)"
            echo "  --cooldown SECS  Seconds between runs (default: 180)"
            echo "  --mpi N          MPI processes (default: auto per system)"
            echo "  --no-mpi         Disable MPI (single-process only)"
            exit 0 ;;
    esac
    shift
done

# =========================================================================
# MPI configuration
# =========================================================================
MPIEXEC=""
if [ "$MPI_PROCS" -ne 1 ] 2>/dev/null; then
    for cmd in mpiexec mpirun; do
        if command -v "$cmd" &>/dev/null; then
            MPIEXEC="$cmd"
            break
        fi
    done
    if [ -z "$MPIEXEC" ]; then
        echo "WARNING: mpiexec/mpirun not found — running single-process"
        MPI_PROCS=1
    fi
else
    MPI_PROCS=1
fi

# Per-system, per-config MPI process count.
#
# Key insight: GPU contention with MPI.
# Each MPI rank creates its own Metal context + command queue. Multiple ranks
# competing for the single GPU causes time-slicing overhead and kills perf.
#
#   amx:      Pure CPU → full MPI (k-point parallelism helps)
#   gpu_amx:  Hybrid → full MPI (most calls fall below threshold with more ranks,
#             so they route to AMX anyway; only big GEMMs hit GPU)
#   gpu_all:  All-GPU → single-process (4 ranks hammering GPU = contention disaster)
#
# Si64 is Γ-only → no k-point parallelism → always single-process.
get_mpi_prefix() {
    local system="$1"
    local config="$2"
    local nprocs="$MPI_PROCS"

    if [ "$nprocs" -eq 1 ]; then
        echo ""
        return
    fi

    if [ "$nprocs" -eq 0 ]; then
        # Auto-detect based on system AND config
        case "$system" in
            ausurf)
                case "$config" in
                    gpu_all)
                        # All GEMMs to GPU — MPI would cause multi-way GPU contention
                        nprocs=1
                        ;;
                    amx|gpu_amx)
                        # CPU-bound or hybrid — MPI helps via k-point parallelism
                        local perf_cores=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || echo 4)
                        if [ "$perf_cores" -ge 8 ]; then
                            nprocs=4  # 4 k-points in AUSURF
                        elif [ "$perf_cores" -ge 4 ]; then
                            nprocs=2
                        else
                            nprocs=1
                        fi
                        ;;
                    *)
                        nprocs=1
                        ;;
                esac
                ;;
            si64)
                # Γ-only: no k-point parallelism, run single-process
                nprocs=1
                ;;
            *)
                nprocs=1
                ;;
        esac
    fi

    if [ "$nprocs" -gt 1 ] && [ -n "$MPIEXEC" ]; then
        echo "$MPIEXEC -n $nprocs"
    else
        echo ""
    fi
}

# Compute OMP threads to avoid oversubscription
get_omp_threads() {
    local mpi_nprocs="$1"
    if [ "$mpi_nprocs" -le 1 ]; then
        echo "${OMP_NUM_THREADS:-4}"
        return
    fi
    local total_cores=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 8)
    local threads=$((total_cores / mpi_nprocs))
    [ "$threads" -lt 1 ] && threads=1
    echo "$threads"
}

# Locate binaries
PW_AMX="$QE_DIR/build-baseline/bin/pw.x"
PW_METAL="$QE_DIR/build-metal/bin/pw.x"

# =========================================================================
# System definitions
# =========================================================================

# Si64 — small, well-characterized, ~7 min/run
SI64_INPUT=""
for path in \
    "$ESPRESSIVO_ROOT/benchmarks/si64.in" \
    "$HOME/qe-test/benchmark/si64.in" \
    "$HOME/qe-test/si64.in"; do
    if [ -f "$path" ]; then
        SI64_INPUT="$path"
        break
    fi
done

# AUSURF112 — medium, 112 atoms, 4 k-points, ~30-60 min/run
AUSURF_INPUT="$QE_DIR/test-suite/benchmarks/pw/ausurf.in"
AUSURF_PSEUDO=""

# Find Au pseudopotential
for dir in \
    "$HOME/qe-test/benchmark" \
    "$HOME/qe-test" \
    "$QE_DIR/pseudo" \
    "$ESPRESSIVO_ROOT/benchmarks/pseudo" \
    "/opt/homebrew/share/qe/pseudo"; do
    if [ -f "$dir/Au.pbe-nd-van.UPF" ]; then
        AUSURF_PSEUDO="$dir"
        break
    fi
done

# =========================================================================
# Setup and validation
# =========================================================================

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="$RESULTS_BASE/$TIMESTAMP"
mkdir -p "$RESULTS_DIR"

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Espressivo: Overnight Multi-System DFT Benchmark               ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Systems:    $SYSTEMS"
echo "  Configs:    $CONFIGS"
echo "  Runs/config: $NUM_RUNS"
echo "  Cooldown:   ${COOLDOWN}s"
echo "  Results:    $RESULTS_DIR"
echo "  Hardware:   $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon')"
echo "  MPI:        ${MPIEXEC:-disabled} (auto per-system: AUSURF=4, Si64=1)"
echo "  OMP_NUM_THREADS: ${OMP_NUM_THREADS:-4} (adjusted per MPI config)"
echo "  apple-bottom: $(grep VERSION_STRING "$AB_DIR/include/apple_bottom.h" 2>/dev/null | head -1 || echo 'unknown')"
echo "  Start time: $(date)"
echo ""

# Validate systems
echo "=== System Validation ==="
if echo "$SYSTEMS" | tr ',' '\n' | grep -q "si64"; then
    if [ -z "$SI64_INPUT" ]; then
        echo "  [!] Si64: input file NOT FOUND — skipping"
        SYSTEMS=$(echo "$SYSTEMS" | sed 's/si64//; s/,,/,/; s/^,//; s/,$//')
    else
        echo "  [✓] Si64: $SI64_INPUT"
    fi
fi
if echo "$SYSTEMS" | tr ',' '\n' | grep -q "ausurf"; then
    if [ ! -f "$AUSURF_INPUT" ]; then
        echo "  [!] AUSURF112: input file NOT FOUND at $AUSURF_INPUT — skipping"
        SYSTEMS=$(echo "$SYSTEMS" | sed 's/ausurf//; s/,,/,/; s/^,//; s/,$//')
    elif [ -z "$AUSURF_PSEUDO" ]; then
        echo "  [!] AUSURF112: Au.pbe-nd-van.UPF NOT FOUND"
        echo "       Download from: https://pseudopotentials.quantum-espresso.org/"
        echo "       Or: wget https://raw.githubusercontent.com/QEF/benchmarks/master/AUSURF112/Au.pbe-nd-van.UPF"
        echo "       Place in: $HOME/qe-test/benchmark/ or $ESPRESSIVO_ROOT/benchmarks/pseudo/"
        SYSTEMS=$(echo "$SYSTEMS" | sed 's/ausurf//; s/,,/,/; s/^,//; s/,$//')
    else
        echo "  [✓] AUSURF112: $AUSURF_INPUT"
        echo "       Pseudo: $AUSURF_PSEUDO/Au.pbe-nd-van.UPF"
    fi
fi

if [ -z "$SYSTEMS" ]; then
    echo ""
    echo "ERROR: No valid systems to benchmark."
    exit 1
fi

echo ""

# Validate binaries
echo "=== Binary Validation ==="
if ! echo "$CONFIGS" | tr ',' '\n' | grep -qE "^(gpu_all|gpu_amx)$" || [ -f "$PW_METAL" ]; then
    true
fi
[ -f "$PW_AMX" ] && echo "  [✓] AMX: $PW_AMX" || echo "  [!] AMX: NOT FOUND"
[ -f "$PW_METAL" ] && echo "  [✓] Metal: $PW_METAL" || echo "  [!] Metal: NOT FOUND"
echo ""

# =========================================================================
# Run a single benchmark
# =========================================================================
run_one() {
    local system="$1"
    local config="$2"
    local run_num="$3"
    local input_file="$4"
    local pseudo_dir="$5"
    local binary="$6"
    local env_override="$7"
    local mpi_prefix="$8"

    local run_dir="$RESULTS_DIR/${system}/${config}/run_${run_num}"
    mkdir -p "$run_dir/tmp"
    cd "$run_dir"

    # Symlink pseudopotentials
    if [ -n "$pseudo_dir" ]; then
        for pp in "$pseudo_dir"/*.upf "$pseudo_dir"/*.UPF "$pseudo_dir"/*.pz-* "$pseudo_dir"/*.pbe-*; do
            [ -f "$pp" ] && ln -sf "$pp" . 2>/dev/null
        done
    fi

    # Also link from input directory
    local input_dir="$(dirname "$input_file")"
    for pp in "$input_dir"/*.upf "$input_dir"/*.UPF; do
        [ -f "$pp" ] && ln -sf "$pp" . 2>/dev/null
    done

    # Compute MPI-aware OMP threads for this run (don't pollute global state)
    local mpi_nprocs=1
    if [ -n "$mpi_prefix" ]; then
        mpi_nprocs=$(echo "$mpi_prefix" | awk '{print $NF}')
    fi
    local run_omp_threads=$(get_omp_threads "$mpi_nprocs")

    local profile_file="$run_dir/ab_profile.log"

    # Log run configuration
    echo "mpi_prefix=$mpi_prefix" > "$run_dir/run_config.txt"
    echo "omp_threads=$run_omp_threads" >> "$run_dir/run_config.txt"
    echo "binary=$binary" >> "$run_dir/run_config.txt"

    # Set ESPRESSO_PSEUDO so QE finds pseudopotentials in run_dir
    # (ausurf.in has no pseudo_dir, so QE uses ESPRESSO_PSEUDO or compiled default)
    local start_time=$(python3 -c "import time; print(time.time())")

    if [ -n "$env_override" ]; then
        env OMP_NUM_THREADS="$run_omp_threads" \
            ESPRESSO_PSEUDO="$run_dir" \
            AB_PROFILE_FILE="$profile_file" $env_override \
            $mpi_prefix "$binary" < "$input_file" > "$run_dir/pw.out" 2>&1 || true
    else
        env OMP_NUM_THREADS="$run_omp_threads" \
            ESPRESSO_PSEUDO="$run_dir" \
            AB_PROFILE_FILE="$profile_file" \
            $mpi_prefix "$binary" < "$input_file" > "$run_dir/pw.out" 2>&1 || true
    fi

    local end_time=$(python3 -c "import time; print(time.time())")
    local wall=$(python3 -c "print(f'{$end_time - $start_time:.1f}')")

    # Extract results
    local energy=$(grep '!' "$run_dir/pw.out" | tail -1 | awk '{print $5}')
    local scf_iter=$(grep 'convergence has been achieved' "$run_dir/pw.out" | awk '{print $6}' | head -1)

    # Check for errors
    local error_check=$(grep -i "error\|stopping\|crash" "$run_dir/pw.out" | head -3)

    local gpu_calls="0"
    local total_calls="0"
    if [ -f "$profile_file" ] && [ -s "$profile_file" ]; then
        gpu_calls=$(grep " 1$" "$profile_file" | wc -l | tr -d ' ')
        local cpu_calls=$(grep " 0$" "$profile_file" | wc -l | tr -d ' ')
        total_calls=$((gpu_calls + cpu_calls))
    fi

    # Save per-run data
    {
        echo "system=$system"
        echo "config=$config"
        echo "run=$run_num"
        echo "wall_time=$wall"
        echo "total_energy=$energy"
        echo "scf_iterations=$scf_iter"
        echo "gpu_calls=$gpu_calls"
        echo "total_calls=$total_calls"
    } > "$run_dir/summary.txt"

    # Append to CSV
    echo "$system,$config,$run_num,$wall,$energy,$scf_iter,$gpu_calls,$total_calls" >> "$RESULTS_DIR/raw_data.csv"

    if [ -n "$error_check" ]; then
        echo "  ${system}/${config} #${run_num}: ${wall}s [ERRORS DETECTED]"
        echo "    $error_check"
    else
        echo "  ${system}/${config} #${run_num}: ${wall}s  E=${energy} Ry  SCF=${scf_iter}  GPU=${gpu_calls}/${total_calls}"
    fi
}

# =========================================================================
# Main execution loop
# =========================================================================

# CSV header
echo "system,config,run,wall_time_s,energy_ry,scf_iters,gpu_calls,total_calls" > "$RESULTS_DIR/raw_data.csv"

# Build run schedule: randomized across all (system, config, run) triples
declare -a SCHEDULE=()

for system in $(echo "$SYSTEMS" | tr ',' ' '); do
    for config in $(echo "$CONFIGS" | tr ',' ' '); do
        for run in $(seq 1 $NUM_RUNS); do
            SCHEDULE+=("${system}:${config}:${run}")
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
echo "=== Randomized schedule: $TOTAL total runs ==="
for entry in "${SCHEDULE[@]}"; do
    echo "    $entry"
done
echo ""
echo "=== Starting at $(date) ==="
echo ""

counter=0
for entry in "${SCHEDULE[@]}"; do
    IFS=':' read -r system config run_num <<< "$entry"
    counter=$((counter + 1))

    echo "--- Run $counter/$TOTAL ---"

    # Select input, pseudo, binary, env
    case "$system" in
        si64)
            input="$SI64_INPUT"
            pseudo="$(dirname "$SI64_INPUT")"
            ;;
        ausurf)
            input="$AUSURF_INPUT"
            pseudo="$AUSURF_PSEUDO"
            ;;
    esac

    case "$config" in
        amx)
            binary="$PW_AMX"
            env_override=""
            ;;
        gpu_all)
            binary="$PW_METAL"
            env_override="AB_CROSSOVER_FLOPS=0"
            ;;
        gpu_amx)
            binary="$PW_METAL"
            env_override=""
            ;;
    esac

    if [ ! -f "$binary" ]; then
        echo "  SKIP: binary not found for $config"
        continue
    fi

    # Get system+config-appropriate MPI prefix
    mpi_prefix=$(get_mpi_prefix "$system" "$config")
    if [ -n "$mpi_prefix" ]; then
        mpi_nprocs=$(echo "$mpi_prefix" | awk '{print $NF}')
        echo "  MPI: $mpi_nprocs procs, OMP: $(get_omp_threads $mpi_nprocs) threads"
    else
        echo "  MPI: off, OMP: $(get_omp_threads 1) threads"
    fi

    run_one "$system" "$config" "$run_num" "$input" "$pseudo" "$binary" "$env_override" "$mpi_prefix"

    # Cooldown between runs
    if [ "$counter" -lt "$TOTAL" ]; then
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

python3 - "$RESULTS_DIR/raw_data.csv" "$RESULTS_DIR" << 'PYEOF'
import sys, statistics

csv_file = sys.argv[1]
results_dir = sys.argv[2]

# Parse
data = {}
with open(csv_file) as f:
    header = f.readline()
    for line in f:
        parts = line.strip().split(',')
        if len(parts) < 6:
            continue
        system, config, run, wall, energy, scf = parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]
        key = (system, config)
        if key not in data:
            data[key] = {'times': [], 'energy': energy, 'scf': scf}
        try:
            data[key]['times'].append(float(wall))
        except ValueError:
            pass

# Generate per-system summaries
systems = sorted(set(k[0] for k in data.keys()))
configs_order = ['amx', 'gpu_all', 'gpu_amx']
config_labels = {
    'amx': 'Accelerate (AMX)',
    'gpu_all': 'GPU DD-BLAS',
    'gpu_amx': 'GPU+AMX hybrid',
}

lines = []
lines.append("Espressivo Overnight Benchmark Results")
lines.append("=" * 70)
lines.append("")

for system in systems:
    lines.append(f"\n{'='*50}")
    lines.append(f"System: {system.upper()}")
    lines.append(f"{'='*50}")
    lines.append("")

    lines.append(f"{'Config':<18}  {'N':>3}  {'Min':>8}  {'Median':>8}  {'Mean':>8}  {'Stdev':>7}  {'Max':>8}  {'Energy'}")
    lines.append(f"{'-'*17:<18}  {'---':>3}  {'---':>8}  {'------':>8}  {'----':>8}  {'-----':>7}  {'---':>8}  {'------'}")

    system_stats = {}
    for config in configs_order:
        key = (system, config)
        if key not in data or not data[key]['times']:
            continue
        t = sorted(data[key]['times'])
        n = len(t)
        median = t[n//2] if n % 2 == 1 else (t[n//2-1] + t[n//2]) / 2
        s = {
            'min': min(t), 'max': max(t), 'mean': statistics.mean(t),
            'stdev': statistics.stdev(t) if n > 1 else 0,
            'median': median, 'energy': data[key]['energy'], 'n': n,
        }
        system_stats[config] = s
        label = config_labels.get(config, config)
        lines.append(f"{label:<18}  {n:>3}  {s['min']:>8.1f}  {s['median']:>8.1f}  {s['mean']:>8.1f}  {s['stdev']:>6.1f}s  {s['max']:>8.1f}  {s['energy']} Ry")

    # Speedup
    amx = system_stats.get('amx')
    if amx:
        lines.append("")
        lines.append("Speedup vs AMX (min times):")
        for config in configs_order:
            if config not in system_stats:
                continue
            s = system_stats[config]
            label = config_labels.get(config, config)
            speedup = amx['min'] / s['min']
            lines.append(f"  {label:<18}  {speedup:.2f}x  ({s['min']:.1f}s)")

    # Variance
    lines.append("")
    lines.append("Variance (thermal stability):")
    for config in configs_order:
        if config not in system_stats:
            continue
        s = system_stats[config]
        label = config_labels.get(config, config)
        cv = (s['stdev'] / s['mean'] * 100) if s['mean'] > 0 else 0
        lines.append(f"  {label:<18}  CV={cv:.1f}%  spread={s['max']-s['min']:.1f}s")

    # Energy match
    energies = set(system_stats[c]['energy'] for c in system_stats)
    if len(energies) == 1:
        lines.append(f"\nENERGY: ALL MATCH ({list(energies)[0]} Ry)")
    else:
        lines.append("\nENERGY: VALUES DIFFER:")
        for c in configs_order:
            if c in system_stats:
                lines.append(f"  {config_labels.get(c,c):<18}  {system_stats[c]['energy']} Ry")

output = '\n'.join(lines)
print(output)

with open(f"{results_dir}/summary.txt", 'w') as f:
    f.write(output + '\n')

print(f"\nSummary saved to: {results_dir}/summary.txt")
PYEOF

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Overnight Benchmark Complete                                    ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Results:    $RESULTS_DIR/"
echo "  Summary:    $RESULTS_DIR/summary.txt"
echo "  Raw CSV:    $RESULTS_DIR/raw_data.csv"
echo "  End time:   $(date)"
