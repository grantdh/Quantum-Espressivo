#!/bin/bash
# build-qe-metal.sh — Clone QE 7.5 developer branch, patch for apple-bottom, build
#
# Usage:
#   ./scripts/build-qe-metal.sh [--baseline-only] [--skip-clone]
#
# This script:
# 1. Clones QE 7.5 from GitLab (developer branch)
# 2. Builds a CPU-only baseline
# 3. Patches cegterg.f90 for apple-bottom GPU acceleration
# 4. Builds the Metal-accelerated version

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESPRESSIVO_ROOT="$(dirname "$SCRIPT_DIR")"
QE_DIR="$ESPRESSIVO_ROOT/deps/qe-7.5"
export APPLE_BOTTOM_DIR="${APPLE_BOTTOM_DIR:-$ESPRESSIVO_ROOT/deps/apple-bottom}"
NPROCS=$(sysctl -n hw.logicalcpu)

# Parse flags
BASELINE_ONLY=false
SKIP_CLONE=false
for arg in "$@"; do
    case $arg in
        --baseline-only) BASELINE_ONLY=true ;;
        --skip-clone) SKIP_CLONE=true ;;
    esac
done

echo "============================================"
echo "Espressivo: Building QE 7.5 with Metal GPU"
echo "============================================"

# Step 0: Verify apple-bottom is built
if [ ! -f "$APPLE_BOTTOM_DIR/build/libapplebottom.a" ]; then
    echo "apple-bottom not found. Running setup..."
    "$SCRIPT_DIR/setup-apple-bottom.sh"
fi

echo "apple-bottom: $APPLE_BOTTOM_DIR"
echo "QE target:    $QE_DIR"
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

# Step 2: Build CPU-only baseline
echo ""
echo "--- Building CPU-only baseline ---"
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
    echo "Building pw.x (baseline)..."
    make -j"$NPROCS" pw 2>&1 | tail -3
    echo "Baseline build complete: $(pwd)/bin/pw.x"
    cd "$QE_DIR"
fi

if [ "$BASELINE_ONLY" = true ]; then
    echo "Baseline-only mode. Done."
    exit 0
fi

# Step 3: Create Metal-accelerated build
echo ""
echo "--- Building Metal-accelerated version ---"

if [ -d "build-metal" ]; then
    echo "Removing previous Metal build..."
    rm -rf build-metal
fi

# Copy source for patching (don't modify the original)
if [ -d "src-metal" ]; then
    echo "Removing previous patched source..."
    rm -rf src-metal
fi
# Use rsync to exclude build directories during copy
rsync -a --exclude='build-baseline' --exclude='build-metal' --exclude='src-metal' --exclude='.git' . src-metal/

cd src-metal

# Step 4: Patch cegterg.f90
echo "Patching cegterg.f90 for apple-bottom..."
CEGTERG="KS_Solvers/Davidson/cegterg.f90"

if [ ! -f "$CEGTERG" ]; then
    # Try alternate location for different QE versions
    CEGTERG=$(find . -name "cegterg.f90" -path "*/Davidson/*" | head -1)
    if [ -z "$CEGTERG" ]; then
        echo "ERROR: Cannot find cegterg.f90"
        exit 1
    fi
fi

echo "Found: $CEGTERG"

# Count existing ZGEMM calls
ZGEMM_COUNT=$(grep -c "CALL ZGEMM" "$CEGTERG" || true)
echo "Found $ZGEMM_COUNT ZGEMM calls to intercept"

# Add EXTERNAL declaration after each IMPLICIT NONE
# This tells Fortran to use our ab_zgemm_ symbol instead of the system BLAS
# NOTE: macOS BSD sed does not interpret \n in replacement strings,
# so we use the 'a\' (append) command with a literal newline instead.
sed -i.bak '/IMPLICIT NONE/a\
      EXTERNAL :: ab_zgemm' "$CEGTERG"

# Replace CALL ZGEMM with CALL ab_zgemm
sed -i.bak 's/CALL ZGEMM/CALL ab_zgemm/g' "$CEGTERG"

# Also handle DGEMM if present
DGEMM_COUNT=$(grep -c "CALL DGEMM" "$CEGTERG" || true)
if [ "$DGEMM_COUNT" -gt 0 ]; then
    echo "Found $DGEMM_COUNT DGEMM calls to intercept"
    # Add EXTERNAL declaration (append to existing one)
    sed -i.bak 's/EXTERNAL :: ab_zgemm/EXTERNAL :: ab_zgemm, ab_dgemm/' "$CEGTERG"
    sed -i.bak 's/CALL DGEMM/CALL ab_dgemm/g' "$CEGTERG"
fi

# Clean up sed backup files
find "$(dirname "$CEGTERG")" -name "*.bak" -delete 2>/dev/null || true

REPLACED=$(grep -c "CALL ab_zgemm" "$CEGTERG" || true)
echo "Patched: $REPLACED ZGEMM calls now route to apple-bottom GPU"

# Patch PW/CMakeLists.txt to link apple-bottom into pw.x
PW_CMAKE="PW/CMakeLists.txt"
if [ -f "$PW_CMAKE" ]; then
    echo "Patching PW/CMakeLists.txt to link apple-bottom..."
    # Add apple-bottom library to pw.x target
    # Find the pw executable target and add target_link_libraries
    if ! grep -q "applebottom" "$PW_CMAKE"; then
        cat >> "$PW_CMAKE" << 'PATCH'

# apple-bottom GPU BLAS (Espressivo patch)
find_library(APPLE_BOTTOM_LIB applebottom HINTS ENV APPLE_BOTTOM_DIR PATH_SUFFIXES lib build)
if(APPLE_BOTTOM_LIB)
    target_link_libraries(qe_pw PRIVATE ${APPLE_BOTTOM_LIB})
    find_library(METAL_FW Metal)
    find_library(FOUNDATION_FW Foundation)
    if(METAL_FW AND FOUNDATION_FW)
        target_link_libraries(qe_pw PRIVATE ${METAL_FW} ${FOUNDATION_FW} "-lc++")
    endif()
    message(STATUS "apple-bottom linked: ${APPLE_BOTTOM_LIB}")
else()
    message(WARNING "apple-bottom not found — GPU acceleration disabled")
endif()
PATCH
        echo "PW/CMakeLists.txt patched."
    fi
fi

cd "$QE_DIR"

# Step 5: Build with apple-bottom
mkdir build-metal && cd build-metal

# apple-bottom must be linked alongside BLAS — inject into all linker targets
AB_LINK_FLAGS="-L${APPLE_BOTTOM_DIR}/build -lapplebottom -framework Metal -framework Foundation -lc++"

cmake ../src-metal \
    -DCMAKE_Fortran_COMPILER=gfortran \
    -DCMAKE_C_COMPILER=gcc-15 \
    -DBLA_VENDOR=Apple \
    -DQE_ENABLE_OPENMP=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_EXE_LINKER_FLAGS="${AB_LINK_FLAGS}" \
    -DCMAKE_SHARED_LINKER_FLAGS="${AB_LINK_FLAGS}" \
    -DCMAKE_MODULE_LINKER_FLAGS="${AB_LINK_FLAGS}" \
    -DCMAKE_Fortran_FLAGS="-O3 -cpp" 2>&1 | tail -10

echo "Building pw.x (Metal-accelerated)..."
make VERBOSE=1 -j"$NPROCS" pw 2>&1 | tee /tmp/qe_metal_build.log | tail -10

# If build failed, show the actual error
if [ ! -f bin/pw.x ]; then
    echo ""
    echo "--- Build failed. Extracting errors from build log ---"
    # Show Fortran compilation errors (most likely cause)
    grep -i "error" /tmp/qe_metal_build.log | grep -v "^make" | head -15
    echo ""
    # Show any linker errors
    grep -i "undefined\|unresolved\|ld:" /tmp/qe_metal_build.log | head -10
fi

# Verify pw.x was actually built
if [ ! -f bin/pw.x ]; then
    echo ""
    echo "============================================"
    echo "ERROR: Metal pw.x build FAILED"
    echo "============================================"
    echo "Check the full build log: /tmp/qe_metal_build.log"
    echo "Common causes:"
    echo "  - Fortran compilation error in patched cegterg.f90"
    echo "  - Missing apple-bottom library linkage"
    echo ""
    echo "To see the actual error:"
    echo "  grep -i 'error' /tmp/qe_metal_build.log | head -20"
    exit 1
fi

# Verify linking
echo ""
echo "--- Verifying apple-bottom linkage ---"
if nm bin/pw.x 2>/dev/null | grep -q "ab_zgemm"; then
    echo "SUCCESS: ab_zgemm_ symbol found in pw.x"
else
    echo "WARNING: ab_zgemm_ symbol not found in pw.x."
    echo "The binary exists but may fall back to system BLAS."
    echo "Check: nm bin/pw.x | grep -i zgemm"
fi

echo ""
echo "============================================"
echo "Build complete!"
echo "  Baseline: $QE_DIR/build-baseline/bin/pw.x"
echo "  Metal:    $QE_DIR/build-metal/bin/pw.x"
echo "============================================"
echo ""
echo "Next: run validation with ./scripts/validate.sh"
