#!/bin/bash
# =============================================================================
# test_qe_integration.sh - Validates apple-bottom QE integration
# =============================================================================
# Usage: ./tests/test_qe_integration.sh
#
# Checks the build that scripts/setup-apple-bottom.sh and scripts/build-qe-metal.sh
# produce (APPLE_BOTTOM_DIR and QE_DIR as in scripts/common.sh):
#   - libapplebottom.dylib exports the Fortran BLAS entry points dgemm_ and zgemm_
#   - QE's Davidson solvers are not patched: linking alone routes their GEMMs
#   - pw.x loads libapplebottom.dylib, and its dgemm_ and zgemm_ bind to it
# scripts/validate.sh then checks the results in AB_MODE=cpu and AB_MODE=gpu.
# =============================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/common.sh"
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

PASS=0
FAIL=0

check() {
    local desc="$1"
    local cmd="$2"
    local expected="$3"

    result=$(eval "$cmd" 2>/dev/null || echo "COMMAND_FAILED")

    if [[ "$result" == *"$expected"* ]]; then
        echo -e "${GREEN}✓${NC} $desc"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗${NC} $desc"
        echo "  Expected: $expected"
        echo "  Got: $result"
        FAIL=$((FAIL + 1))
    fi
}

echo "=============================================="
echo "apple-bottom QE Integration Test Suite"
echo "=============================================="
echo "apple-bottom: $APPLE_BOTTOM_DIR"
echo "QE:           $QE_DIR"
echo ""

# ---------------------------------------------
# Step 1: Library symbols
# ---------------------------------------------
echo "--- Step 1: Library Symbols ---"
LIB="$APPLE_BOTTOM_DIR/build/libapplebottom.dylib"

check "Library exists" "test -f '$LIB' && echo exists" "exists"
check "_dgemm_ exported (Fortran BLAS)" "nm -gU '$LIB' | awk '{print \$NF}' | grep -x _dgemm_" "_dgemm_"
check "_zgemm_ exported (Fortran BLAS)" "nm -gU '$LIB' | awk '{print \$NF}' | grep -x _zgemm_" "_zgemm_"

# ---------------------------------------------
# Step 2: QE source is not patched
# ---------------------------------------------
echo ""
echo "--- Step 2: QE Source Files ---"
for f in cegterg regterg; do
    src="$QE_DIR/KS_Solvers/Davidson/$f.f90"
    check "$f.f90 calls ZGEMM/DGEMM unchanged (no ab_*gemm)" \
        "test -f '$src' && { grep -qi 'ab_[dz]gemm' '$src' && echo patched || echo unpatched; }" \
        "unpatched"
done

# ---------------------------------------------
# Step 3: pw.x binary
# ---------------------------------------------
echo ""
echo "--- Step 3: pw.x Binary ---"
PW="$QE_DIR/build-metal/bin/pw.x"

check "pw.x exists" "test -x '$PW' && echo executable" "executable"
check "pw.x loads libapplebottom.dylib" "otool -L '$PW'" "@rpath/libapplebottom.dylib"
BINDINGS=$(check_gemm_bindings "$PW")
check "dgemm_ binds to libapplebottom" "echo '$BINDINGS'" "<libapplebottom.dylib/_dgemm_>"
check "zgemm_ binds to libapplebottom" "echo '$BINDINGS'" "<libapplebottom.dylib/_zgemm_>"

# ---------------------------------------------
# Summary
# ---------------------------------------------
echo ""
echo "=============================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================================="

if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}All checks passed!${NC}"
    echo ""
    echo "To check the results with the GEMMs on the CPU and on the GPU:"
    echo "  ./scripts/validate.sh"
    exit 0
else
    echo -e "${RED}Some checks failed. Review output above.${NC}"
    exit 1
fi
