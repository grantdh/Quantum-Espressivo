#!/bin/bash
# build-qe-openblas.sh — Build QE 7.5 linked against Homebrew OpenBLAS (no AMX)
#
# Usage:
#   ./scripts/build-qe-openblas.sh
#
# Prerequisites:
#   brew install openblas
#
# This builds a QE that uses pure software FP64 BLAS — no Apple AMX,
# no GPU. Useful as the "CPU-only" baseline in the 4-way benchmark.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESPRESSIVO_ROOT="$(dirname "$SCRIPT_DIR")"
QE_DIR="$ESPRESSIVO_ROOT/deps/qe-7.5"
NPROCS=$(sysctl -n hw.logicalcpu)

echo "============================================"
echo "Espressivo: Building QE 7.5 with OpenBLAS"
echo "============================================"

# Check for OpenBLAS
OPENBLAS_PREFIX="$(brew --prefix openblas 2>/dev/null || true)"
if [ -z "$OPENBLAS_PREFIX" ] || [ ! -d "$OPENBLAS_PREFIX" ]; then
    echo "ERROR: OpenBLAS not found. Install with: brew install openblas"
    exit 1
fi
echo "OpenBLAS: $OPENBLAS_PREFIX"

# Verify QE source exists
if [ ! -f "$QE_DIR/CMakeLists.txt" ]; then
    echo "ERROR: QE source not found at $QE_DIR"
    echo "Run ./scripts/build-qe-metal.sh first to clone QE."
    exit 1
fi

cd "$QE_DIR"

BUILD_DIR="build-openblas"
if [ -d "$BUILD_DIR" ]; then
    echo "Removing previous OpenBLAS build..."
    rm -rf "$BUILD_DIR"
fi

mkdir "$BUILD_DIR" && cd "$BUILD_DIR"

# Force CMake to find OpenBLAS, NOT Accelerate
# Setting BLA_VENDOR=OpenBLAS and providing explicit paths
cmake .. \
    -DCMAKE_Fortran_COMPILER=gfortran \
    -DCMAKE_C_COMPILER=gcc-15 \
    -DBLA_VENDOR=OpenBLAS \
    -DQE_ENABLE_OPENMP=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DBLAS_LIBRARIES="${OPENBLAS_PREFIX}/lib/libopenblas.dylib" \
    -DLAPACK_LIBRARIES="${OPENBLAS_PREFIX}/lib/libopenblas.dylib" \
    -DCMAKE_C_FLAGS="-I${OPENBLAS_PREFIX}/include" \
    -DCMAKE_Fortran_FLAGS="-O3" 2>&1 | tail -10

echo "Building pw.x (OpenBLAS)..."
make -j"$NPROCS" pw 2>&1 | tail -5

if [ ! -f bin/pw.x ]; then
    echo "ERROR: OpenBLAS build failed"
    exit 1
fi

# Verify it links against OpenBLAS, not Accelerate
echo ""
echo "--- Verifying linkage ---"
if otool -L bin/pw.x | grep -q "libopenblas"; then
    echo "SUCCESS: pw.x links against OpenBLAS"
elif otool -L bin/pw.x | grep -q "Accelerate"; then
    echo "WARNING: pw.x links against Accelerate (AMX) — not pure OpenBLAS"
    echo "CMake may have ignored BLA_VENDOR. Check cmake output."
fi

echo ""
echo "============================================"
echo "OpenBLAS build complete: $(pwd)/bin/pw.x"
echo "============================================"
