#!/bin/bash
# build-qe-openblas.sh — Build QE linked against Homebrew OpenBLAS (no AMX)
#
# Usage:
#   ./scripts/build-qe-openblas.sh
#
# Prerequisites:
#   brew install openblas
#
# This builds a QE that uses pure software FP64 BLAS — no Apple AMX,
# no GPU. Useful as the "CPU-only" baseline in the 4-way benchmark.
# It builds the same tree with the same settings as build-qe-metal.sh.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "============================================"
echo "Espressivo: Building QE with OpenBLAS"
echo "============================================"

# Check for OpenBLAS
OPENBLAS_PREFIX="$(brew --prefix openblas 2>/dev/null || true)"
if [ -z "$OPENBLAS_PREFIX" ] || [ ! -d "$OPENBLAS_PREFIX" ]; then
    echo "ERROR: OpenBLAS not found. Install with: brew install openblas"
    exit 1
fi
echo "OpenBLAS: $OPENBLAS_PREFIX"

fetch_commit "$QE_DIR" "$QE_URL" "$QE_COMMIT"

BUILD_DIR="$QE_DIR/build-openblas"
if [ -d "$BUILD_DIR" ]; then
    echo "Removing previous OpenBLAS build..."
    rm -rf "$BUILD_DIR"
fi

# Force CMake to find OpenBLAS, NOT Accelerate
# Setting BLA_VENDOR=OpenBLAS and providing explicit paths
build_pw "$BUILD_DIR" "${QE_CMAKE_ARGS[@]}" \
    -DBLA_VENDOR=OpenBLAS \
    -DBLAS_LIBRARIES="${OPENBLAS_PREFIX}/lib/libopenblas.dylib" \
    -DLAPACK_LIBRARIES="${OPENBLAS_PREFIX}/lib/libopenblas.dylib" \
    -DCMAKE_C_FLAGS="-I${OPENBLAS_PREFIX}/include" || exit 1

write_provenance "$BUILD_DIR"

# Verify it links against OpenBLAS, not Accelerate
echo ""
echo "--- Verifying linkage ---"
if otool -L "$BUILD_DIR/bin/pw.x" | grep -q "libopenblas"; then
    echo "SUCCESS: pw.x links against OpenBLAS"
elif otool -L "$BUILD_DIR/bin/pw.x" | grep -q "Accelerate"; then
    echo "WARNING: pw.x links against Accelerate (AMX) — not pure OpenBLAS"
    echo "CMake may have ignored BLA_VENDOR. Check cmake output."
fi

echo ""
echo "============================================"
echo "OpenBLAS build complete: $BUILD_DIR/bin/pw.x"
echo "============================================"
