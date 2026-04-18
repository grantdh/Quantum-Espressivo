#!/bin/bash
# rebuild-metal.sh — Sync apple-bottom from local dev repo and rebuild QE Metal binary
#
# This is the one-command rebuild script. It:
#   1. Syncs apple-bottom source from the local dev repo (metal-algos)
#   2. Rebuilds libapplebottom.a
#   3. Rebuilds QE Metal binary (pw.x) with the updated library
#
# Usage:
#   ./scripts/rebuild-metal.sh                          # default: looks for ~/Dev/metal-algos
#   ./scripts/rebuild-metal.sh --ab-dev /path/to/repo   # explicit path to apple-bottom dev repo
#   ./scripts/rebuild-metal.sh --skip-qe                # only rebuild library, don't rebuild QE
#   ./scripts/rebuild-metal.sh --full                    # also rebuild baseline (for benchmarking)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESPRESSIVO_ROOT="$(dirname "$SCRIPT_DIR")"
AB_PROD="$ESPRESSIVO_ROOT/deps/apple-bottom"
QE_DIR="$ESPRESSIVO_ROOT/deps/qe-7.5"
NPROCS=$(sysctl -n hw.logicalcpu)

# Defaults
AB_DEV=""
SKIP_QE=false
FULL_REBUILD=false

# Parse flags
while [ $# -gt 0 ]; do
    case $1 in
        --ab-dev)    shift; AB_DEV="$1" ;;
        --ab-dev=*)  AB_DEV="${1#*=}" ;;
        --skip-qe)   SKIP_QE=true ;;
        --full)      FULL_REBUILD=true ;;
        -h|--help)
            echo "Usage: $0 [--ab-dev /path/to/dev/repo] [--skip-qe] [--full]"
            echo ""
            echo "  --ab-dev PATH   Path to apple-bottom dev repo (default: ~/Dev/metal-algos)"
            echo "  --skip-qe       Only rebuild libapplebottom.a, skip QE rebuild"
            echo "  --full           Also rebuild QE baseline binary"
            exit 0 ;;
    esac
    shift
done

# Auto-detect dev repo
if [ -z "$AB_DEV" ]; then
    for path in \
        "$HOME/Dev/metal-algos" \
        "$HOME/dev/metal-algos" \
        "$HOME/metal-algos" \
        "$HOME/Dev/apple-bottom"; do
        if [ -d "$path/.git" ]; then
            AB_DEV="$path"
            break
        fi
    done
fi

if [ -z "$AB_DEV" ] || [ ! -d "$AB_DEV/.git" ]; then
    echo "ERROR: Cannot find apple-bottom dev repo."
    echo "Provide with --ab-dev /path/to/your/dev/repo"
    exit 1
fi

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Espressivo: Rebuild Metal Pipeline                              ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# =========================================================================
# Step 1: Sync apple-bottom source from dev repo
# =========================================================================
echo "=== Step 1: Sync apple-bottom source ==="
echo "  Dev repo: $AB_DEV"
echo "  Target:   $AB_PROD"

# Show what's changing
DEV_COMMIT=$(git -C "$AB_DEV" rev-parse --short HEAD)
DEV_MSG=$(git -C "$AB_DEV" log -1 --format="%s")
PROD_COMMIT=$(git -C "$AB_PROD" rev-parse --short HEAD 2>/dev/null || echo "none")
PROD_MSG=$(git -C "$AB_PROD" log -1 --format="%s" 2>/dev/null || echo "none")

echo "  Dev:  $DEV_COMMIT ($DEV_MSG)"
echo "  Prod: $PROD_COMMIT ($PROD_MSG)"

if [ "$DEV_COMMIT" = "$PROD_COMMIT" ]; then
    echo "  Already up to date."
else
    AHEAD=$(git -C "$AB_DEV" rev-list --count "$PROD_COMMIT".."$DEV_COMMIT" 2>/dev/null || echo "?")
    echo "  Dev is $AHEAD commits ahead."
    echo ""
    echo "  Syncing source files..."

    # Sync source, headers, tests, benchmarks, and build files
    for item in src include tests benchmarks Makefile CMakeLists.txt; do
        if [ -e "$AB_DEV/$item" ]; then
            rsync -a --delete "$AB_DEV/$item" "$AB_PROD/" 2>/dev/null || \
            cp -R "$AB_DEV/$item" "$AB_PROD/"
        fi
    done

    # Sync Metal shader if present
    if [ -d "$AB_DEV/shaders" ]; then
        rsync -a --delete "$AB_DEV/shaders" "$AB_PROD/" 2>/dev/null || \
        cp -R "$AB_DEV/shaders" "$AB_PROD/"
    fi

    echo "  Source synced."
fi
echo ""

# =========================================================================
# Step 2: Rebuild libapplebottom.a
# =========================================================================
echo "=== Step 2: Rebuild libapplebottom.a ==="
cd "$AB_PROD"

# Clean and rebuild
make clean 2>/dev/null || rm -rf build
make -j"$NPROCS" 2>&1 | tail -5

# Verify
if [ ! -f "build/libapplebottom.a" ]; then
    echo "ERROR: libapplebottom.a build FAILED"
    exit 1
fi

# Run tests
echo ""
echo "  Running tests..."
make test 2>&1 | grep -E "passed|PASSED|failed|FAILED|Results:|All.*tests" | head -5

# Check for warnings
WARN_COUNT=$(make 2>&1 | grep -c "warning:" || true)
if [ "$WARN_COUNT" -gt 0 ]; then
    echo "  WARNING: $WARN_COUNT compiler warnings detected"
    make 2>&1 | grep "warning:" | head -5
else
    echo "  Zero warnings."
fi

LIB_SIZE=$(wc -c < build/libapplebottom.a | tr -d ' ')
echo "  Built: build/libapplebottom.a ($LIB_SIZE bytes)"
echo ""

if [ "$SKIP_QE" = true ]; then
    echo "=== Skipping QE rebuild (--skip-qe) ==="
    echo ""
    echo "Done. Library updated at: $AB_PROD/build/libapplebottom.a"
    exit 0
fi

# =========================================================================
# Step 3: Rebuild QE Metal binary
# =========================================================================
echo "=== Step 3: Rebuild QE Metal binary ==="

if [ ! -d "$QE_DIR/src-metal" ]; then
    echo "  No patched QE source found. Running full build..."
    "$SCRIPT_DIR/build-qe-metal.sh" --skip-clone
    exit $?
fi

if [ ! -d "$QE_DIR/build-metal" ]; then
    echo "  No previous Metal build found. Running full build..."
    "$SCRIPT_DIR/build-qe-metal.sh" --skip-clone
    exit $?
fi

cd "$QE_DIR/build-metal"

# Just rebuild pw.x — the apple-bottom .a is already in the linker flags
echo "  Rebuilding pw.x with updated libapplebottom.a..."

# Touch the fortran bridge object to force relink
# (The .a changed, but make might not notice since it's an external lib)
find . -name "pw.x" -delete 2>/dev/null || true

make -j"$NPROCS" pw 2>&1 | tail -5

if [ ! -f bin/pw.x ]; then
    echo ""
    echo "  Incremental rebuild failed. Trying clean rebuild..."
    rm -rf "$QE_DIR/build-metal"
    "$SCRIPT_DIR/build-qe-metal.sh" --skip-clone
    exit $?
fi

# Verify linking
if nm bin/pw.x 2>/dev/null | grep -q "ab_zgemm"; then
    echo "  ab_zgemm_ symbol found in pw.x"
else
    echo "  WARNING: ab_zgemm_ symbol NOT found"
fi

PW_SIZE=$(wc -c < bin/pw.x | tr -d ' ')
echo "  Built: bin/pw.x ($PW_SIZE bytes)"

# =========================================================================
# Step 4 (optional): Rebuild baseline
# =========================================================================
if [ "$FULL_REBUILD" = true ]; then
    echo ""
    echo "=== Step 4: Rebuild baseline binary ==="
    if [ -d "$QE_DIR/build-baseline" ]; then
        cd "$QE_DIR/build-baseline"
        make -j"$NPROCS" pw 2>&1 | tail -3
        echo "  Baseline rebuilt."
    else
        "$SCRIPT_DIR/build-qe-metal.sh" --baseline-only --skip-clone
    fi
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Rebuild Complete                                                ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  apple-bottom: $DEV_COMMIT ($DEV_MSG)"
echo "  Metal pw.x:   $QE_DIR/build-metal/bin/pw.x"
echo ""
echo "  Next steps:"
echo "    ./scripts/validate.sh           # quick correctness check"
echo "    ./scripts/benchmark-4way.sh     # full benchmark suite"
echo "    ./scripts/benchmark-paper.sh    # paper-ready tables"
