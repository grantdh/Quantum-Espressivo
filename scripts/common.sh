# common.sh — sourced by the scripts in this directory and by benchmarks/qe_yambo/config.sh:
# where the dependencies live, the commits the build scripts fetch, and the helpers the scripts
# share. Set any of the variables in the environment to override it.

ESPRESSIVO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NPROCS=$(sysctl -n hw.logicalcpu)

# apple-bottom v1.4.0. setup-apple-bottom.sh fetches it into deps/apple-bottom; point
# APPLE_BOTTOM_DIR at another built checkout to use that one instead.
APPLE_BOTTOM_URL="${APPLE_BOTTOM_URL:-https://github.com/grantdh/apple-bottom.git}"
APPLE_BOTTOM_COMMIT="${APPLE_BOTTOM_COMMIT:-01765e1fc8e9b55ab2818976686ee9461b92b571}"
APPLE_BOTTOM_DIR="${APPLE_BOTTOM_DIR:-$ESPRESSIVO_ROOT/deps/apple-bottom}"

# Quantum ESPRESSO develop of 2026-10-30 (it reports version 8.0dev). build-qe-metal.sh,
# build-qe-accelerate.sh and build-qe-openblas.sh all build this tree.
QE_URL="${QE_URL:-https://gitlab.com/QEF/q-e.git}"
QE_COMMIT="${QE_COMMIT:-b6615c50b360515ab52a376df5e5c76be285fc2e}"
QE_DIR="${QE_DIR:-$ESPRESSIVO_ROOT/deps/qe}"

# CMake settings shared by the QE builds, so that they differ only in their BLAS.
QE_CMAKE_ARGS=(
    -DCMAKE_Fortran_COMPILER=gfortran
    -DCMAKE_C_COMPILER=gcc-15
    -DQE_ENABLE_OPENMP=ON
    -DCMAKE_BUILD_TYPE=Release
)

# --- Fetching and building -----------------------------------------------------

# fetch_commit DIR URL COMMIT: check out COMMIT of URL in DIR, fetching it if DIR does not
# exist yet. An existing DIR is used as it is, with a warning if it is at another commit.
fetch_commit() {
    local dir="$1" url="$2" commit="$3" head
    if [ ! -e "$dir" ]; then
        echo "Fetching $url at $commit into $dir"
        git init -q "$dir"
        git -C "$dir" remote add origin "$url"
        git -C "$dir" fetch -q --depth 1 origin "$commit"
        git -C "$dir" checkout -q FETCH_HEAD
    fi
    head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "not a git checkout")
    if [ "$head" != "$commit" ]; then
        echo "WARNING: $dir is at $head, not at the pinned $commit"
    fi
}

# git_desc DIR: the commit checked out in DIR, with -dirty if tracked files differ from it.
git_desc() {
    local head
    head=$(git -C "$1" rev-parse HEAD 2>/dev/null) || { echo "not a git checkout"; return; }
    [ -z "$(git -C "$1" status --porcelain --untracked-files=no 2>/dev/null)" ] || head="$head-dirty"
    echo "$head"
}

# build_apple_bottom: build libapplebottom.dylib in APPLE_BOTTOM_DIR and run apple-bottom's
# tests, which use the GPU.
build_apple_bottom() {
    make -C "$APPLE_BOTTOM_DIR" -j"$NPROCS" lib && make -C "$APPLE_BOTTOM_DIR" test
}

# ab_link_flags: the linker flags that put apple-bottom ahead of the BLAS that CMake finds; the
# rpath lets pw.x find libapplebottom.dylib in APPLE_BOTTOM_DIR/build.
ab_link_flags() {
    echo "-L$APPLE_BOTTOM_DIR/build -Wl,-rpath,$APPLE_BOTTOM_DIR/build -lapplebottom"
}

# build_pw BUILD_DIR [CMAKE_ARGS...]: configure QE_DIR into BUILD_DIR (reconfiguring an existing
# one) and build pw.x, logging to BUILD_DIR/cmake.log and BUILD_DIR/build.log. Call it as
# "build_pw ... || exit 1": it reports a failure and returns 1.
build_pw() {
    local dir="$1"
    shift
    mkdir -p "$dir"
    echo "Configuring (log: $dir/cmake.log)..."
    if ! cmake -S "$QE_DIR" -B "$dir" "$@" > "$dir/cmake.log" 2>&1; then
        tail -30 "$dir/cmake.log"
        echo "ERROR: CMake failed; see $dir/cmake.log"
        return 1
    fi
    echo "Building pw.x (log: $dir/build.log)..."
    if ! cmake --build "$dir" --target pw --parallel "$NPROCS" --verbose > "$dir/build.log" 2>&1; then
        grep -E -i "error|undefined" "$dir/build.log" | head -20
        echo "ERROR: the pw.x build failed; see $dir/build.log"
        return 1
    fi
}

# links_apple_bottom BINARY: whether BINARY loads libapplebottom.dylib.
links_apple_bottom() {
    [[ "$(otool -L "$1" 2>/dev/null)" == *libapplebottom* ]]
}

# check_gemm_bindings PW: print where pw.x's dgemm_ and zgemm_ bind at load time, and fail
# unless both bind to libapplebottom.dylib, as apple-bottom's integration guide checks. Open
# MPI's link flags make QE's link flat-namespace: each symbol binds to the first library
# loaded that exports it. pw.x stops at once on the empty input.
check_gemm_bindings() {
    local pw tmp bindings
    pw="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    tmp=$(mktemp -d)
    bindings=$(cd "$tmp" && DYLD_PRINT_BINDINGS=1 "$pw" -in /dev/null < /dev/null 2>&1 \
               | grep -oE '<[^<>]*/_[dz]gemm_>' | sort -u || true)
    rm -rf "$tmp"
    echo "${bindings:-(no bindings printed)}"
    if [ "$(echo "$bindings" | grep -c '^<libapplebottom\.dylib/')" -ne 2 ]; then
        echo "ERROR: dgemm_ and zgemm_ do not both bind to libapplebottom.dylib"
        return 1
    fi
}

# write_provenance BUILD_DIR: record what the QE build in BUILD_DIR was made from in
# BUILD_DIR/PROVENANCE.txt. pw.x loads libapplebottom.dylib from APPLE_BOTTOM_DIR/build when it
# runs, so the build string in each run's profile names the library that run used.
write_provenance() {
    {
        echo "date: $(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "qe: $(git_desc "$QE_DIR") ($QE_DIR)"
        if links_apple_bottom "$1/bin/pw.x"; then
            echo "apple-bottom at link time: $(git_desc "$APPLE_BOTTOM_DIR") ($APPLE_BOTTOM_DIR)"
            echo "link: $(ab_link_flags), ahead of the BLAS"
        fi
        echo "gfortran: $(gfortran --version | head -1)"
        echo "gcc-15: $(gcc-15 --version | head -1)"
        echo "mpi: $(mpirun --version 2>/dev/null | head -1)"
        echo "cmake: $(cmake --version | head -1)"
        echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    } > "$1/PROVENANCE.txt"
}

# --- apple-bottom's profile of a run ------------------------------------------------

# Launch a program as "[mpirun ...] $AB_WITH_PROFILE PREFIX PROGRAM ARGS...", with a PREFIX of
# its own for each run: every process writes its profile to PREFIX.<pid>.json. "ab_summary
# PREFIX" adds them up and prints "<gpu_calls> <cpu_calls> <gpu_time_pct> <build>", or NA four
# times (with the reason on stderr) if a process wrote none.
AB_WITH_PROFILE="$ESPRESSIVO_ROOT/scripts/with-ab-profile.sh"
ab_summary() {
    python3 "$ESPRESSIVO_ROOT/scripts/ab_profile.py" "$1" || echo NA NA NA NA
}

# ab_kv GPU_CALLS CPU_CALLS GPU_TIME_PCT BUILD: ab_summary's fields as summary.txt lines.
ab_kv() {
    printf 'gpu_calls=%s\ncpu_calls=%s\ngpu_time_pct=%s\nab_build=%s\n' "$1" "$2" "$3" "$4"
}

# --- pw.x output ----------------------------------------------------------------------

# qe_energy OUT: the final total energy (Ry) in pw.x output OUT; empty if it has none.
qe_energy() {
    awk '/^!/ {e = $(NF-1)} END {print e}' "$1"
}

# qe_iterations OUT: the SCF iterations to convergence in pw.x output OUT; empty if it did not
# converge.
qe_iterations() {
    awk '/convergence has been achieved/ {n = $6} END {print n}' "$1"
}

# --- Host -------------------------------------------------------------------------------

# Performance cores (0 if sysctl does not report them), and a one-line description of the
# machine for reports.
P_CORES=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo 0)
host_desc() {
    local chip e mem gpu
    chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon')
    e=$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null || echo '?')
    mem=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
    # Only ioreg reports the GPU core count; read to the end so ioreg never sees SIGPIPE.
    gpu=$(ioreg -rc AGXAccelerator -d1 2>/dev/null | awk -F'= ' '/"gpu-core-count"/{n=$2} END{print n}') || gpu=''
    echo "${chip} (${P_CORES} P-cores + ${e} E-cores, ${gpu:-?}-core GPU, ${mem} GB), macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"
}
