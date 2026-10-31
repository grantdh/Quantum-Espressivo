#!/bin/bash
# Build QE's pw.x twice from one tree: linked to apple-bottom as in its integration guide (pw.x.cpu),
# and the same objects linked again with qe_split.o in front (pw.x.split). Records what it did in
# $OUT/PROVENANCE.txt.
#
# Usage: QE_DIR=... AB_LIB=... AB_INC=... OUT=... split/build-qe.sh
#   QE_DIR      a QE checkout with its submodules; cloned from QE's develop branch if it does not exist
#   AB_LIB      directory holding the libapplebottom.dylib to link (and load, through the rpath)
#   AB_INC      directory holding apple_bottom.h, from the library's commit
#   OUT         where the binaries, make.inc variants, logs and PROVENANCE.txt go
#   AB_LIB_FIX  optional: also pw.x.fix, pw.x.split with its rpath pointed at this library instead,
#               ad-hoc re-signed (the library's public header must equal AB_INC's)
#   JOBS        make -j (default 8);  LOCK_BUILD  prefix for configure and make (e.g. a machine lock)
# Toolchain: Homebrew gcc-15/gfortran-15 behind Open MPI's wrappers, OpenBLAS, ScaLAPACK, FFTW.
# The configure line and the make.inc edits are those of apple-bottom's 1.5.0 QE release check:
# -D__FFTW3, Homebrew's include directory, cpp-15, threaded FFTW, and apple-bottom ahead of both
# LAPACK_LIBS and BLAS_LIBS. FFLAGS stay configure's -O3 -g -fopenmp.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${QE_DIR:?}" "${AB_LIB:?}" "${AB_INC:?}" "${OUT:?}"
JOBS="${JOBS:-8}"
LOCK="${LOCK_BUILD:-}"
export OMPI_CC=gcc-15 OMPI_FC=gfortran-15
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
P="$OUT/PROVENANCE.txt"
say() { echo "== $(date '+%F %T') $*" | tee -a "$OUT/build.log"; }
sha() { shasum -a 256 "$1" | cut -c1-64; }
rpaths() { otool -l "$1" | awk '/LC_RPATH/ { getline; getline; print $2 }' | tr '\n' ' '; }

if [ ! -d "$QE_DIR" ]; then
  say "clone QE develop into $QE_DIR"
  git clone --branch develop https://gitlab.com/QEF/q-e.git "$QE_DIR" >> "$OUT/build.log" 2>&1
  (cd "$QE_DIR" && git submodule update --init --recursive) >> "$OUT/build.log" 2>&1
fi
cd "$QE_DIR"
{
  echo "QE pw.x, with and without qe_split.o; written $(date '+%F %T %Z') on $(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "tree:    $QE_DIR"
  echo "commit:  $(git log -1 --format='%H %cI %s')"
  echo "version: $(grep version_number include/qe_version.h | sed -E "s/.*'(.*)'.*/\1/")"
  echo "status:  $(git status --porcelain | tr '\n' ' ')"
  echo "submodules:"; git submodule status | sed 's/^/  /'
  echo "toolchain: $(brew list --versions gcc open-mpi openblas scalapack fftw | tr '\n' ';')"
  echo "library: $AB_LIB/libapplebottom.dylib sha256 $(sha "$AB_LIB/libapplebottom.dylib")"
  echo "header:  $AB_INC/apple_bottom.h sha256 $(sha "$AB_INC/apple_bottom.h")"
} > "$P"

if [ ! -f "$OUT/make.inc.configure" ]; then
  say "configure"
  $LOCK ./configure --enable-openmp MPIF90=mpif90 CC=mpicc \
    'BLAS_LIBS=-L/opt/homebrew/opt/openblas/lib -lopenblas' 'LAPACK_LIBS=-L/opt/homebrew/opt/openblas/lib -lopenblas' \
    'SCALAPACK_LIBS=-L/opt/homebrew/opt/scalapack/lib -lscalapack' 'FFT_LIBS=-L/opt/homebrew/lib -lfftw3' \
    > "$OUT/configure.out" 2>&1
  cp make.inc "$OUT/make.inc.configure"
fi
# The release check's edits. configure must have written what it wrote then, or we stop.
val() { awk -v v="$1" '$1 == v && $2 == "=" { sub(/^[^=]*= */, ""); print; exit }' "$OUT/make.inc.configure"; }
expect() {  # <variable> <value> [<another accepted value>]
  local v; v="$(val "$1")"
  [ "$v" = "$2" ] && return
  [ $# -gt 2 ] && [ "$v" = "$3" ] && return
  say "configure wrote $1 = '$v'"; exit 1
}
expect DFLAGS '-D__MPI -D__MPI_MODULE -D__SCALAPACK' '-D__FFTW3 -D__MPI -D__MPI_MODULE -D__SCALAPACK'
expect IFLAGS '-I. -I$(TOPDIR)/include'
expect CPP cpp
expect FFT_LIBS '-L/opt/homebrew/lib -lfftw3'
expect FFLAGS '-O3 -g -fallow-argument-mismatch -fopenmp'
awk 'function set(v) { sub(/=.*/, "= " v) }
     $1 == "DFLAGS" && $2 == "=" { set("-D__FFTW3 -D__MPI -D__MPI_MODULE -D__SCALAPACK") }
     $1 == "IFLAGS" && $2 == "=" { set("-I/opt/homebrew/include -I. -I$(TOPDIR)/include") }
     $1 == "CPP" && $2 == "=" { set("cpp-15") }
     $1 == "FFT_LIBS" && $2 == "=" { set("-L/opt/homebrew/lib -lfftw3_omp -lfftw3") }
     { print }' "$OUT/make.inc.configure" > "$OUT/make.inc.cpu"
cat >> "$OUT/make.inc.cpu" <<EOF

# apple-bottom, linked as in its integration guide (docs/INTEGRATION.md, Quantum ESPRESSO Integration)
AB_LIBS     = -L$AB_LIB -Wl,-rpath,$AB_LIB -lapplebottom
LAPACK_LIBS := \$(AB_LIBS) \$(LAPACK_LIBS)
BLAS_LIBS   := \$(AB_LIBS) \$(BLAS_LIBS)
EOF
cp "$OUT/make.inc.cpu" "$OUT/make.inc.split"
cat >> "$OUT/make.inc.split" <<EOF
# qe_split.o defines dgemm_ and zgemm_ (an object file's definitions take precedence over a library's)
SPLIT_OBJ   = $OUT/qe_split.o
BLAS_LIBS   := \$(SPLIT_OBJ) \$(BLAS_LIBS)
EOF

say "qe_split.o and test_split"
make -s -C "$HERE" OUT="$OUT" AB_INC="$AB_INC" AB_LIB="$AB_LIB" "$OUT/qe_split.o" "$OUT/test_split" >> "$OUT/build.log" 2>&1

manifest() { find . \( -name '*.o' -o -name '*.a' -o -name '*.mod' -o -name '*.x' \) -type f ! -path ./PW/src/pw.x -print0 | sort -z | xargs -0 shasum -a 256; }
link() {  # <make.inc variant> <log>: make pw with make.inc.<variant>, leaving PW/src/pw.x
  cp "$OUT/make.inc.$1" make.inc
  rm -f PW/src/pw.x
  say "make pw ($1)"
  $LOCK make pw -j"$JOBS" > "$OUT/$2" 2>&1 || { say "make pw ($1) failed, see $2"; exit 1; }
}
if [ ! -f "$OUT/pw.x.cpu" ]; then link cpu build-cpu.log; cp PW/src/pw.x "$OUT/pw.x.cpu"; manifest > "$OUT/objects-cpu.sha256"; fi
if [ ! -f "$OUT/pw.x.split" ]; then link split build-split.log; cp PW/src/pw.x "$OUT/pw.x.split"; manifest > "$OUT/objects-split.sha256"; fi
cmp -s "$OUT/objects-cpu.sha256" "$OUT/objects-split.sha256" || { say "the split link changed objects other than pw.x"; exit 1; }
link cpu build-relink-cpu.log  # leaves the tree linked as pw.x.cpu, which it must reproduce
cmp -s PW/src/pw.x "$OUT/pw.x.cpu" && relink=identical || relink=DIFFERENT

if [ -n "${AB_LIB_FIX:-}" ]; then
  cp "$OUT/pw.x.split" "$OUT/pw.x.fix"
  install_name_tool -rpath "$AB_LIB" "$AB_LIB_FIX" "$OUT/pw.x.fix" 2>/dev/null
  codesign -s - -f "$OUT/pw.x.fix" 2>/dev/null
fi

{
  echo "make.inc: configure output make.inc.configure; make.inc.cpu adds the release check's edits and"
  echo "  apple-bottom; make.inc.split adds qe_split.o in front of BLAS_LIBS. diff make.inc.cpu make.inc.split:"
  diff "$OUT/make.inc.cpu" "$OUT/make.inc.split" | sed 's/^/    /' || true
  echo "  FFLAGS: $(val FFLAGS); CFLAGS: $(val CFLAGS)"
  echo "objects: one build (make pw -j$JOBS); pw.x.split relinks the same objects (objects-*.sha256 equal);"
  echo "  pw.x relinked with make.inc.cpu afterwards is $relink to pw.x.cpu"
  echo "qe_split.o: $(sha "$OUT/qe_split.o"), from split/qe_split.c $(sha "$HERE/qe_split.c")"
  for v in cpu split ${AB_LIB_FIX:+fix}; do
    b="$OUT/pw.x.$v"
    echo "pw.x.$v: sha256 $(sha "$b"), $(stat -f %z "$b") bytes, $(dwarfdump --uuid "$b" | awk '{print $2}' | head -1)"
    echo "  dgemm_/zgemm_: $(nm -m "$b" | grep -E ' _[dz]gemm_$' | sed -E 's/^[0-9a-f]* *//' | tr '\n' ';')"
    echo "  libraries:     $(otool -L "$b" | tail -n +2 | awk '{print $1}' | grep -E 'applebottom|Accelerate|openblas|fftw|scalapack|mpi' | tr '\n' ' ')"
    echo "  LC_RPATH:      $(rpaths "$b")"
  done
  if [ -n "${AB_LIB_FIX:-}" ]; then
    echo "pw.x.fix: pw.x.split with LC_RPATH $AB_LIB -> $AB_LIB_FIX, ad-hoc re-signed; library sha256 $(sha "$AB_LIB_FIX/libapplebottom.dylib")"
  fi
} >> "$P"
# Open MPI's wrappers link with -flat_namespace: pw.x.cpu's zgemm_ binds at run time to the first
# library loaded that exports it, which must be apple-bottom; pw.x.split defines its own.
grep -q '(__TEXT,__text) external _zgemm_' <(nm -m "$OUT/pw.x.split") || { say "pw.x.split does not define zgemm_"; exit 1; }
grep -q '(undefined) external _zgemm_' <(nm -m "$OUT/pw.x.cpu") || { say "pw.x.cpu defines zgemm_"; exit 1; }
otool -L "$OUT/pw.x.cpu" | awk 'NR > 1 {print $1}' | grep -E 'libapplebottom|libopenblas|Accelerate' | head -1 | grep -q libapplebottom ||
  { say "pw.x.cpu loads another BLAS before apple-bottom"; exit 1; }
[ -z "${AB_LIB_FIX:-}" ] || rpaths "$OUT/pw.x.fix" | grep -q "^$AB_LIB_FIX " || { say "pw.x.fix's rpath is not $AB_LIB_FIX"; exit 1; }
say "done: pw.x.cpu, pw.x.split${AB_LIB_FIX:+, pw.x.fix} in $OUT (relink $relink)"
