#!/bin/bash
# build-qe-metal.sh — build Quantum ESPRESSO's pw.x linked against apple-bottom
#
# Usage:
#   ./scripts/build-qe-metal.sh
#
# Produces deps/qe/build-metal/bin/pw.x. It fetches QE at the commit pinned in common.sh
# (unless deps/qe exists) and builds apple-bottom first if it is not built. QE's source is not
# changed: libapplebottom.dylib is linked ahead of Accelerate, so QE's dgemm_ and zgemm_ calls
# go to apple-bottom, and AB_MODE (cpu, auto or gpu) decides at run time where they run.
#
# Sibling scripts build the same tree with the same settings and another BLAS:
#   build-qe-accelerate.sh -> deps/qe/build-baseline/bin/pw.x  (Accelerate)
#   build-qe-openblas.sh   -> deps/qe/build-openblas/bin/pw.x  (OpenBLAS)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
BUILD_DIR="$QE_DIR/build-metal"

echo "============================================"
echo "Espressivo: building QE with apple-bottom"
echo "============================================"

if [ ! -f "$APPLE_BOTTOM_DIR/build/libapplebottom.dylib" ]; then
    "$SCRIPT_DIR/setup-apple-bottom.sh"
fi
fetch_commit "$QE_DIR" "$QE_URL" "$QE_COMMIT"
echo "apple-bottom: $APPLE_BOTTOM_DIR"
echo "QE:           $QE_DIR"
echo ""

rm -rf "$BUILD_DIR"
build_pw "$BUILD_DIR" "${QE_CMAKE_ARGS[@]}" -DBLA_VENDOR=Apple \
    -DCMAKE_EXE_LINKER_FLAGS="$(ab_link_flags)" || exit 1

echo ""
echo "--- Where pw.x's dgemm_ and zgemm_ bind ---"
check_gemm_bindings "$BUILD_DIR/bin/pw.x" || exit 1
write_provenance "$BUILD_DIR"

echo ""
echo "============================================"
echo "Built: $BUILD_DIR/bin/pw.x"
echo "============================================"
cat "$BUILD_DIR/PROVENANCE.txt"
echo ""
echo "Next: ./scripts/validate.sh"
