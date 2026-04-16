#!/usr/bin/env bash
# Build QE 7.5 into a *parallel* folder linked against apple-bottom.
# Never modifies the clean source tree at $QE_SRC_CLEAN — mirrors first.
#
# Follows the authoritative recipe from CLAUDE.md Section 4/5:
#   - configure with BLAS/LAPACK/SCALAPACK/FFT_LIBS set explicitly
#   - force -D__FFTW3 into DFLAGS, -I/opt/homebrew/include into IFLAGS
#   - APPLE_BOTTOM_LIBS := -L.../build -lapplebottom + Metal/Foundation/
#     CoreGraphics/Accelerate frameworks + -lc++
#   - augment QE 7.5's link rule which only reads LDFLAGS and QELIBS
#
# Output:  ${QE_BUILD_DIR}/bin/pw.x   (links libapplebottom.dylib)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/config.sh"

echo "================== build_qe_ab.sh =================="
echo "  Source (clean) : ${QE_SRC_CLEAN}"
echo "  Build target   : ${QE_BUILD_DIR}"
echo "  apple-bottom   : ${AB_LIB}"
echo "===================================================="

# --- preflight ------------------------------------------------------------
[[ -d "${QE_SRC_CLEAN}" ]] || { echo "ERROR: QE clean source missing: ${QE_SRC_CLEAN}"; exit 1; }
[[ -f "${AB_LIB}" ]] || { echo "ERROR: apple-bottom dylib not built. Run 'make dylib' in ${AB_ROOT}"; exit 1; }
[[ -f "${AB_INCLUDE}/apple_bottom.h" ]] || { echo "ERROR: apple-bottom header missing"; exit 1; }

# --- mirror source --------------------------------------------------------
if [[ -d "${QE_BUILD_DIR}" ]]; then
    echo "[skip] ${QE_BUILD_DIR} already exists."
    echo "       Delete it to force re-mirror, or run 'make clean && make pw' inside."
else
    echo "[mirror] cp -a ${QE_SRC_CLEAN} -> ${QE_BUILD_DIR}"
    mkdir -p "$(dirname "${QE_BUILD_DIR}")"
    cp -a "${QE_SRC_CLEAN}" "${QE_BUILD_DIR}"
fi

cd "${QE_BUILD_DIR}"

# --- patch cegterg.f90 / regterg.f90 --------------------------------------
CEGTERG="KS_Solvers/Davidson/cegterg.f90"
if grep -q "ab_zgemm" "${CEGTERG}"; then
    echo "[patch] cegterg.f90 already uses ab_zgemm"
else
    echo "[patch] cegterg.f90: CALL ZGEMM -> CALL ab_zgemm"
    cp "${CEGTERG}" "${CEGTERG}.orig"
    perl -i -pe 's/\bCALL\s+ZGEMM\b/CALL ab_zgemm/gi' "${CEGTERG}"
fi
REGTERG="KS_Solvers/Davidson/regterg.f90"
if [[ -f "${REGTERG}" ]] && ! grep -q "ab_dgemm" "${REGTERG}"; then
    echo "[patch] regterg.f90: CALL DGEMM -> CALL ab_dgemm"
    cp "${REGTERG}" "${REGTERG}.orig"
    perl -i -pe 's/\bCALL\s+DGEMM\b/CALL ab_dgemm/gi' "${REGTERG}"
fi

# --- strip any previous injection so we always start from a clean make.inc
if [[ -f make.inc ]] && grep -q "apple-bottom injection" make.inc 2>/dev/null; then
    echo "[clean] removing previous apple-bottom injection from make.inc"
    sed -i.bak '/# === apple-bottom injection/,$d' make.inc
fi

# --- configure (only if make.inc does not yet exist) ----------------------
# Per CLAUDE.md Section 5: pass BLAS/LAPACK/SCALAPACK/FFT_LIBS explicitly so
# QE's configure wires them correctly and emits -D__FFTW3 / -lfftw3.
if [[ ! -f make.inc ]]; then
    BLAS_FLAG="-L/opt/homebrew/opt/openblas/lib -lopenblas"
    LAPACK_FLAG="-L/opt/homebrew/opt/openblas/lib -lopenblas"
    SCALAPACK_FLAG="-L/opt/homebrew/opt/scalapack/lib -lscalapack"
    FFT_FLAG="-L/opt/homebrew/lib -lfftw3"
    echo "[configure] ./configure --enable-openmp --with-scalapack=no \\"
    echo "              BLAS_LIBS=\"${BLAS_FLAG}\" LAPACK_LIBS=\"${LAPACK_FLAG}\" \\"
    echo "              SCALAPACK_LIBS=\"${SCALAPACK_FLAG}\" FFT_LIBS=\"${FFT_FLAG}\""
    ./configure --enable-openmp \
        MPIF90=mpif90 CC=mpicc \
        BLAS_LIBS="${BLAS_FLAG}" \
        LAPACK_LIBS="${LAPACK_FLAG}" \
        SCALAPACK_LIBS="${SCALAPACK_FLAG}" \
        FFT_LIBS="${FFT_FLAG}"
fi

# --- force FFTW3 DFLAG + homebrew include if configure missed them --------
if ! grep -q "__FFTW3" make.inc; then
    echo "[make.inc] injecting -D__FFTW3 into DFLAGS"
    sed -i.bak1 's|^DFLAGS *= *|DFLAGS         = -D__FFTW3 |' make.inc
fi
if ! grep -q "homebrew/include" make.inc; then
    echo "[make.inc] injecting -I/opt/homebrew/include into IFLAGS"
    sed -i.bak2 's|^IFLAGS *= *|IFLAGS         = -I/opt/homebrew/include |' make.inc
fi

# --- capture MPI Fortran link flags --------------------------------------
# QE 7.5's exe link rule is: $(LD) $(LDFLAGS) -o pw.x ... $(QELIBS)
# Only LDFLAGS and QELIBS survive to the link line; we must make sure
# MPI Fortran libs (mpi_mpifh, libmpi, ...) are pulled in there.
MPI_LINK_FLAGS="$(mpif90 --showme:link 2>/dev/null || true)"
if [[ -n "${MPI_LINK_FLAGS}" ]]; then
    echo "[mpi] mpif90 --showme:link: ${MPI_LINK_FLAGS}"
else
    echo "[mpi] WARNING: mpif90 --showme:link unavailable — MPI symbols may be missing"
fi

# --- apple-bottom injection ----------------------------------------------
# APPLE_BOTTOM_LIBS matches CLAUDE.md Section 4 exactly — frameworks and -lc++
# are required because libapplebottom.dylib is an Obj-C++/Metal hybrid.
echo "[make.inc] injecting apple-bottom linkage (per CLAUDE.md Section 4)"
cat >> make.inc <<EOF

# === apple-bottom injection (appended by build_qe_ab.sh) =========
# Snapshot stock values with := so we don't create recursive Make vars.
_AB_BLAS_ORIG    := \$(BLAS_LIBS)
_AB_LAPACK_ORIG  := \$(LAPACK_LIBS)
_AB_SCA_ORIG     := \$(SCALAPACK_LIBS)

AB_LIB_DIR       := ${AB_ROOT}/build
APPLE_BOTTOM_LIBS := -L\$(AB_LIB_DIR) -Wl,-rpath,\$(AB_LIB_DIR) -lapplebottom \\
                    -framework Metal -framework Foundation \\
                    -framework CoreGraphics -framework Accelerate -lc++
# Hardcoded scalapack — don't trust snapshot (configure may have dropped it).
AB_SCALAPACK_LIBS := -L/opt/homebrew/opt/scalapack/lib -lscalapack
MPI_LINK_LIBS    := ${MPI_LINK_FLAGS}

# Use mpif90 as the linker so the MPI Fortran runtime comes along.
LD               := mpif90

# QE 7.5's pw.x link rule only passes LDFLAGS and QELIBS — put everything there.
LDFLAGS          := \$(LDFLAGS) \$(APPLE_BOTTOM_LIBS) \$(AB_SCALAPACK_LIBS) \$(MPI_LINK_LIBS)
override QELIBS  += \$(APPLE_BOTTOM_LIBS) \$(AB_SCALAPACK_LIBS) \$(MPI_LINK_LIBS)

# Keep the stock BLAS/LAPACK vars populated so internal QE rules don't break,
# but prepend apple-bottom so ab_zgemm / ab_dgemm resolve before openblas.
BLAS_LIBS        := \$(APPLE_BOTTOM_LIBS) \$(_AB_BLAS_ORIG)
LAPACK_LIBS      := \$(APPLE_BOTTOM_LIBS) \$(_AB_LAPACK_ORIG)
MPI_LIBS         := \$(MPI_LINK_LIBS)
LD_LIBS          := \$(MPI_LINK_LIBS)
EOF

# --- build ----------------------------------------------------------------
NPROC="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
echo "[make] pw ( -j${NPROC} )"
make -j"${NPROC}" pw 2>&1 | tail -30

# --- verify ---------------------------------------------------------------
if [[ -x bin/pw.x ]]; then
    echo ""
    echo "[verify] otool -L bin/pw.x | grep applebottom"
    otool -L bin/pw.x | grep -E "applebottom|libab" || {
        echo "  FAIL — pw.x built but does not link libapplebottom.dylib"
        exit 1
    }
    echo ""
    echo "✓ QE+apple-bottom build complete: ${QE_BUILD_DIR}/bin/pw.x"
else
    echo "✗ pw.x was not produced"
    exit 1
fi
