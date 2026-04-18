#!/bin/bash
# build-qe-accelerate.sh — Build QE 7.5 with Apple Accelerate (AMX) only
#
# Usage:
#   ./scripts/build-qe-accelerate.sh [--skip-clone]
#
# Single responsibility: produces deps/qe-7.5/build-baseline/bin/pw.x with
# BLA_VENDOR=Apple. Consumed by:
#   - benchmark-paper.sh    as PW_AMX
#   - benchmark-4way.sh     as PW_AMX
#   - benchmark-overnight.sh as PW_AMX
#   - calibrate-omp.sh      as PW_AMX
#   - validate.sh           as BASELINE_PW
#   - rebuild-metal.sh      (--full mode) as the rebuild target
#
# This script was extracted from build-qe-metal.sh so each build target
# (openblas / accelerate / metal) has a single-responsibility script.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESPRESSIVO_ROOT="$(dirname "$SCRIPT_DIR")"
QE_DIR="$ESPRESSIVO_ROOT/deps/qe-7.5"
NPROCS=$(sysctl -n hw.logicalcpu)

# Parse flags
SKIP_CLONE=false
for arg in "$@"; do
    case $arg in
        --skip-clone) SKIP_CLONE=true ;;
    esac
done

echo "============================================"
echo "Espressivo: Building QE 7.5 with Apple Accelerate (AMX)"
echo "============================================"
echo "QE target: $QE_DIR"
echo ""

# Step 1: Clone QE 7.5
if [ "$SKIP_CLONE" = false ]; then
    if [ -d "$QE_DIR" ]; then
        echo "QE 7.5 already exists at $QE_DIR"
        echo "Use --skip-clone to reuse, or remove it first."
        read -p "Remove and re-clone? [y/N] " answer
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            rm -rf "$QE_DIR"
        else
            SKIP_CLONE=true
        fi
    fi

    if [ "$SKIP_CLONE" = false ]; then
        echo "Cloning QE 7.5 from GitLab developer branch..."
        mkdir -p "$ESPRESSIVO_ROOT/deps"
        git clone --branch develop --depth 1 https://gitlab.com/QEF/q-e.git "$QE_DIR"
        echo "QE 7.5 cloned successfully."
    fi
fi

cd "$QE_DIR"

# Step 2: Build Accelerate/AMX baseline
echo ""
echo "--- Building Accelerate/AMX baseline ---"
if [ -d "build-baseline" ]; then
    echo "Baseline build exists, skipping. Remove build-baseline/ to rebuild."
else
    mkdir build-baseline && cd build-baseline
    cmake .. \
        -DCMAKE_Fortran_COMPILER=gfortran \
        -DCMAKE_C_COMPILER=gcc-15 \
        -DBLA_VENDOR=Apple \
        -DQE_ENABLE_OPENMP=ON \
        -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -5
    echo "Building pw.x (Accelerate/AMX)..."
    make -j"$NPROCS" pw 2>&1 | tail -3

    if [ ! -f bin/pw.x ]; then
        echo ""
        echo "ERROR: Accelerate baseline build FAILED"
        exit 1
    fi

    # Verify linking against Accelerate framework
    echo ""
    echo "--- Verifying linkage ---"
    if otool -L bin/pw.x | grep -q "Accelerate"; then
        echo "SUCCESS: pw.x links against Accelerate"
    else
        echo "WARNING: pw.x does not link Accelerate — CMake may have substituted another BLAS"
    fi
fi

echo ""
echo "============================================"
echo "Accelerate baseline build complete: $QE_DIR/build-baseline/bin/pw.x"
echo "============================================"
