# Benchmark path configuration — populated from recon.sh output.
# Override any of these via environment before invoking the scripts.

# --- apple-bottom dylib ----------------------------------------------------
: "${AB_ROOT:=$HOME/Dev/arm/metal-algos}"
: "${AB_LIB:=${AB_ROOT}/build/libapplebottom.dylib}"
: "${AB_INCLUDE:=${AB_ROOT}/include}"

# --- QE: source + target build dirs ---------------------------------------
# Clean 7.5 tree to patch from (don't touch this — we'll mirror it to BUILD_DIR)
: "${QE_SRC_CLEAN:=$HOME/qe-test/q-e-7.5}"
# Fresh parallel build folder (created from a mirror of QE_SRC_CLEAN)
: "${QE_BUILD_DIR:=$HOME/qe-test/builds/mpi-gpu-ab}"
# Existing working pw.x (for baseline comparison / sanity)
: "${PW_BIN_EXISTING:=$HOME/qe-test/builds/mpi-gpu/pw.x}"
# What the benchmark actually runs:
: "${PW_BIN:=${QE_BUILD_DIR}/bin/pw.x}"

# --- QE input decks --------------------------------------------------------
# Benchmark inputs are *generated* by generate_inputs.sh into inputs/<sys>/scf.in
# (so we control ecutwfc, pseudo, kgrid — not whatever legacy .in files exist).
# Search roots are consulted as a fallback for hand-curated inputs.
: "${BENCH_HOME:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${BENCH_INPUT_DIR:=${BENCH_HOME}/inputs}"
QE_SEARCH_ROOTS=(
    "${BENCH_INPUT_DIR}"
    "$HOME/qe-test/benchmark"
    "$HOME/qe-test/systems"
)

# --- Pseudopotential -------------------------------------------------------
# SG15 ONCV PBE v1.0 (what's actually on disk — spec asked for v1.2 but v1.0
# is fine for a BLAS benchmark: we measure dispatch routing, not convergence).
: "${PSEUDO_DIR:=$HOME/qe-test/wannier90/pseudo}"
: "${PSEUDO_SI:=Si_ONCV_PBE-1.0.upf}"

# --- Yambo: source + target build dirs ------------------------------------
# Source tree with the ab_zgemm modifications already applied (confirmed by recon)
: "${YAMBO_SRC:=$HOME/yambo-build/yambo}"
: "${YAMBO_BUILD_DIR:=$HOME/yambo-build/builds/dp-mpi-gpu-ab}"
: "${YAMBO_BIN_EXISTING:=$HOME/yambo-build/builds/dp-mpi-gpu/yambo}"
: "${YAMBO_BIN:=${YAMBO_BUILD_DIR}/yambo}"

# --- Yambo input templates -------------------------------------------------
: "${YAMBO_TEMPLATE_ROOT:=$HOME/Dev/yambo-build}"
: "${YAMBO_TEMPLATE_gaas:=$HOME/Dev/yambo-build/gaas-bse}"
# Stage input files inside the template dir (flat layout, from recon)
: "${YAMBO_GW_IN:=yambo_gw.in}"
: "${YAMBO_BSE_IN:=yambo_bse.in}"

# --- Run parameters --------------------------------------------------------
# Single MPI rank + single-threaded OpenMP: we're isolating BLAS dispatch time,
# not measuring parallel scaling. MPI and OpenMP both add noise that would
# contaminate the AB_MODE comparison.
: "${NP:=1}"
: "${OMP:=1}"
: "${QE_TIMEOUT:=3600}"
: "${YAMBO_TIMEOUT:=7200}"
# OpenMPI Apple-Clang guard (per CLAUDE.md prior notes)
: "${OMPI_CC:=/opt/homebrew/bin/gcc-15}"
: "${OMPI_FC:=/opt/homebrew/bin/gfortran-15}"
export OMPI_CC OMPI_FC

# --- Color helpers (degrade gracefully when stdout is not a tty) ----------
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
    C_BLU=$'\033[34m'; C_BLD=$'\033[1m';  C_RST=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_BLD=''; C_RST=''
fi
ts() { date "+%Y-%m-%dT%H:%M:%S"; }

# --- Helpers ---------------------------------------------------------------
qe_input_file() {
    # Returns the .in path for a given system name.
    local sys="$1"
    local var="QE_INPUT_${sys}"
    if [[ -n "${!var:-}" && -f "${!var}" ]]; then
        echo "${!var}"; return 0
    fi
    local root
    for root in "${QE_SEARCH_ROOTS[@]}"; do
        [[ -f "${root}/${sys}.in" ]] && { echo "${root}/${sys}.in"; return 0; }
        [[ -f "${root}/${sys}/pw.in" ]] && { echo "${root}/${sys}/pw.in"; return 0; }
    done
    return 1
}

yambo_template_dir() {
    local sys="$1"
    local var="YAMBO_TEMPLATE_${sys}"
    if [[ -n "${!var:-}" && -d "${!var}" ]]; then
        echo "${!var}"; return 0
    fi
    return 1
}

check_applebottom_link() {
    local bin="$1"
    if [[ ! -x "${bin}" ]]; then
        echo "  (binary not executable: ${bin})"
        return
    fi
    if otool -L "${bin}" 2>/dev/null | grep -qiE "applebottom|libab"; then
        echo "  OK — ${bin} links against apple-bottom"
    else
        echo "  WARN — ${bin} does NOT link libapplebottom.dylib"
    fi
}
