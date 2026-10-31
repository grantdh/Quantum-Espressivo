#!/bin/bash
# build-qe-accelerate.sh — build Quantum ESPRESSO's pw.x with Apple Accelerate as its BLAS
#
# Usage:
#   ./scripts/build-qe-accelerate.sh
#
# Produces deps/qe/build-baseline/bin/pw.x from the same tree and CMake settings as
# build-qe-metal.sh, without apple-bottom (fetching QE at the commit pinned in common.sh unless
# deps/qe exists). Used as PW_AMX by benchmark-paper.sh, benchmark-4way.sh,
# benchmark-overnight.sh and calibrate-omp.sh. An existing build is kept: remove
# deps/qe/build-baseline to rebuild it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
BUILD_DIR="$QE_DIR/build-baseline"

echo "============================================"
echo "Espressivo: building QE with Apple Accelerate"
echo "============================================"

fetch_commit "$QE_DIR" "$QE_URL" "$QE_COMMIT"
echo "QE: $QE_DIR"
echo ""

if [ -d "$BUILD_DIR" ]; then
    echo "Baseline build exists, skipping. Remove $BUILD_DIR to rebuild."
    exit 0
fi

build_pw "$BUILD_DIR" "${QE_CMAKE_ARGS[@]}" -DBLA_VENDOR=Apple || exit 1

echo ""
echo "--- Verifying linkage ---"
if [[ "$(otool -L "$BUILD_DIR/bin/pw.x")" == *Accelerate* ]]; then
    echo "SUCCESS: pw.x links against Accelerate"
else
    echo "WARNING: pw.x does not link Accelerate — CMake may have substituted another BLAS"
fi
write_provenance "$BUILD_DIR"

echo ""
echo "============================================"
echo "Built: $BUILD_DIR/bin/pw.x"
echo "============================================"
