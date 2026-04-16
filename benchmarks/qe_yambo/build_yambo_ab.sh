#!/usr/bin/env bash
# Build Yambo 5.3.0 (DP+MPI+GPU) into a parallel folder linked against apple-bottom.
# The existing source tree at ${YAMBO_SRC} already has mod_wrapper{,_omp}.F patched.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/config.sh"

echo "================== build_yambo_ab.sh ==================="
echo "  Yambo src      : ${YAMBO_SRC}"
echo "  Build target   : ${YAMBO_BUILD_DIR}"
echo "  apple-bottom   : ${AB_LIB}"
echo "========================================================"

# --- preflight ------------------------------------------------------------
[[ -d "${YAMBO_SRC}" ]] || { echo "ERROR: Yambo source tree missing: ${YAMBO_SRC}"; exit 1; }
[[ -f "${AB_LIB}" ]] || { echo "ERROR: libapplebottom.dylib missing — build it first"; exit 1; }

# Verify modifications are already in the source
for f in src/modules/mod_wrapper.F src/modules/mod_wrapper_omp.F; do
    if ! grep -q "ab_zgemm\|ab_dgemm" "${YAMBO_SRC}/${f}" 2>/dev/null; then
        echo "WARN: ${f} does not appear to have ab_{z,d}gemm calls — proceeding anyway."
    fi
done

# --- mirror source --------------------------------------------------------
# We don't copy the entire Yambo tree (large) — we make a build-only directory
# and re-run configure pointing at the patched source. Yambo supports VPATH-ish
# out-of-tree builds via configure --prefix + make.
if [[ -x "${YAMBO_BUILD_DIR}/yambo" ]]; then
    echo "[skip] yambo binary already built at ${YAMBO_BUILD_DIR}/yambo"
    echo "       rm -rf it to force a clean rebuild."
else
    mkdir -p "${YAMBO_BUILD_DIR}"
fi

# --- configure in-place (Yambo is not fully VPATH-clean) ------------------
# We run configure inside the original source tree; make install goes into
# ${YAMBO_BUILD_DIR} so the validated builds/dp-mpi-gpu/ tree is untouched.
cd "${YAMBO_SRC}"

# Inject apple-bottom + frameworks into LIBS/LDFLAGS through env.
# Per CLAUDE.md Section 4: Obj-C++/Metal dylib needs the frameworks + -lc++.
AB_FRAMEWORKS="-framework Metal -framework Foundation -framework CoreGraphics -framework Accelerate -lc++"
export LIBS="-L${AB_ROOT}/build -Wl,-rpath,${AB_ROOT}/build -lapplebottom ${AB_FRAMEWORKS} ${LIBS:-}"
export LDFLAGS="-L${AB_ROOT}/build -Wl,-rpath,${AB_ROOT}/build ${LDFLAGS:-}"
export CPPFLAGS="-I${AB_INCLUDE} ${CPPFLAGS:-}"

echo "[configure] env overlay:"
echo "  LIBS=${LIBS}"
echo "  LDFLAGS=${LDFLAGS}"

# --- re-run configure with stored args via autoconf's --recheck -----------
# config.status --recheck replays the exact original configure invocation
# (no eval / no quote mangling) and honors our LIBS/LDFLAGS/CPPFLAGS overlay.
if [[ -x ./config.status ]]; then
    echo "[configure] ./config.status --recheck"
    ./config.status --recheck
else
    echo "[configure] no config.status — running fresh ./configure"
    ./configure --prefix="${YAMBO_BUILD_DIR}" \
        --enable-dp --enable-open-mp --enable-mpi \
        --with-mpi-path=/opt/homebrew \
        --with-blas-libs="-L/opt/homebrew/opt/openblas/lib -lopenblas" \
        --with-lapack-libs="-L/opt/homebrew/opt/openblas/lib -lopenblas" \
        --with-fft-path=/opt/homebrew \
        --with-hdf5-path=/opt/homebrew \
        --with-netcdf-path=/opt/homebrew \
        --with-netcdff-path=/opt/homebrew/opt/netcdf-fortran \
        --with-libxc-path=/opt/homebrew/opt/libxc \
        --with-blacs-libs="-L/opt/homebrew/opt/scalapack/lib -lscalapack" \
        --with-scalapack-libs="-L/opt/homebrew/opt/scalapack/lib -lscalapack"
fi

# --- patch config/setup lblas with rpath ----------------------------------
# Yambo's link rule consumes $lblas from config/setup. configure wires
# -lapplebottom into it (via --with-blas-libs or LIBS env), but does NOT add
# a matching -Wl,-rpath,..., so the dylib's @rpath install_name won't resolve
# at runtime. Inject rpath next to the -lapplebottom token.
if grep -q "lapplebottom" config/setup && ! grep -q "rpath,${AB_ROOT}/build" config/setup; then
    echo "[patch] adding -Wl,-rpath,${AB_ROOT}/build to config/setup:lblas"
    sed -i.bak "s|-lapplebottom|-Wl,-rpath,${AB_ROOT}/build -lapplebottom|" config/setup
fi

# --- build (clean relink is required — setup-only regen won't touch yambo) -
echo "[make clean + yambo]"
make clean >/dev/null 2>&1 || true
make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" yambo 2>&1 | tail -30

# Yambo writes to bin/ inside the source tree — copy out.
if [[ -x bin/yambo ]]; then
    cp bin/yambo "${YAMBO_BUILD_DIR}/yambo"
    cp bin/ypp "${YAMBO_BUILD_DIR}/ypp" 2>/dev/null || true
    cp bin/p2y "${YAMBO_BUILD_DIR}/p2y" 2>/dev/null || true
fi

# --- verify ---------------------------------------------------------------
if [[ -x "${YAMBO_BUILD_DIR}/yambo" ]]; then
    echo ""
    echo "[verify] otool -L ${YAMBO_BUILD_DIR}/yambo | grep applebottom"
    otool -L "${YAMBO_BUILD_DIR}/yambo" | grep -E "applebottom|libab" || {
        echo "  FAIL — yambo built but does not link libapplebottom.dylib"
        echo "  (make_inc may have clobbered LIBS — inspect ${YAMBO_SRC}/config/*.mk)"
        exit 1
    }
    echo ""
    echo "✓ Yambo+apple-bottom build complete: ${YAMBO_BUILD_DIR}/yambo"
else
    echo "✗ yambo was not produced"
    exit 1
fi
