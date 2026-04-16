#!/usr/bin/env bash
# bench_yambo.sh — run two Yambo calculations (IP-RPA, reduced GW-PPA)
# against a pre-built SAVE directory in all three AB_MODE policies.
#
# Prereqs (checked before anything else runs):
#   - $YAMBO_SAVE_DIR exists and contains ns.db1
#   - Yambo binary (${YAMBO_BIN}) exists AND links libapplebottom.dylib
#   - yambo CLI is in PATH (used for `-setup`)
#
# IMPORTANT: The SAVE must come from a Yambo-style NSCF
#   nosym=.false., force_symmorphic=.true.
# NOT from an EPW NSCF. We can't detect this from the binary DB — we can only
# warn loudly and trust the user.
#
# Two stages per mode:
#   B1: IP-RPA            — light ZGEMM, mostly dipoles/IO (baseline overhead)
#   B2: GW-PPA (reduced)  — ZGEMM-dominated (where apple-bottom should shine)
# We skip BSE: full GW+BSE is the "days" path per workflow notes, way more
# than we need to prove dispatch routing.
#
# Usage: ./bench_yambo.sh <system_id> [--gaas | --vbm N --cbm M] \
#                                     [--save /path/to/SAVE]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/config.sh"

SYSTEM="${1:-gaas}"
shift || true

# Default VBM/CBM — safe for small Si cells. --gaas sets GaAs values.
VBM=4; CBM=5
USER_SAVE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gaas)   VBM=9; CBM=10; shift ;;
        --vbm)    VBM="$2"; shift 2 ;;
        --cbm)    CBM="$2"; shift 2 ;;
        --save)   USER_SAVE="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# --- resolve SAVE dir -----------------------------------------------------
SAVE_DIR="${USER_SAVE:-${YAMBO_SAVE_DIR:-}}"
if [[ -z "${SAVE_DIR}" ]]; then
    if TEMPLATE_DIR="$(yambo_template_dir "${SYSTEM}")" && [[ -d "${TEMPLATE_DIR}/SAVE" ]]; then
        SAVE_DIR="${TEMPLATE_DIR}/SAVE"
    fi
fi
if [[ -z "${SAVE_DIR}" || ! -d "${SAVE_DIR}" ]]; then
    echo "${C_RED}ERROR${C_RST}: no SAVE directory found for '${SYSTEM}'."
    echo "  Set YAMBO_SAVE_DIR=... or pass --save /path/to/SAVE"
    echo "  Expected SAVE to contain at minimum: ns.db1"
    exit 1
fi
if [[ ! -f "${SAVE_DIR}/ns.db1" ]]; then
    echo "${C_RED}ERROR${C_RST}: ${SAVE_DIR}/ns.db1 missing — did p2y run?"
    exit 1
fi

# --- binary linkage preflight --------------------------------------------
if [[ ! -x "${YAMBO_BIN}" ]]; then
    echo "${C_RED}ERROR${C_RST}: YAMBO_BIN not executable: ${YAMBO_BIN}"
    echo "       Run ./build_yambo_ab.sh first."
    exit 1
fi
if ! otool -L "${YAMBO_BIN}" 2>/dev/null | grep -qE "applebottom|libab"; then
    echo "${C_RED}ERROR${C_RST}: ${YAMBO_BIN} is NOT linked against libapplebottom.dylib."
    exit 1
fi

echo ""
echo "${C_YLW}WARNING${C_RST}: ensure ${SAVE_DIR} was generated from a Yambo NSCF"
echo "         (nosym=.false., force_symmorphic=.true.), NOT an EPW NSCF."
echo "         Reusing an EPW NSCF produces WRONG results."
echo ""
echo "[$(ts)] SAVE : ${SAVE_DIR}"
echo "[$(ts)] bin  : ${YAMBO_BIN}"
echo "[$(ts)] bands: VBM=${VBM}  CBM=${CBM}"
echo ""

OUT_ROOT="${HERE}/results/yambo_${SYSTEM}"
mkdir -p "${OUT_ROOT}"

# --- stage: copy SAVE into per-mode dir (symlinks confuse some Yambo versions
# when they touch SAVE for caching). Trade a few MB for safety. ------------
stage_save() {
    local dest="$1"
    if [[ -L "${dest}/SAVE" || -e "${dest}/SAVE" ]]; then rm -rf "${dest}/SAVE"; fi
    cp -R "${SAVE_DIR}" "${dest}/SAVE"
}

# --- determine NKPTS from the first yambo -setup run ---------------------
probe_dir="${OUT_ROOT}/_probe"
rm -rf "${probe_dir}"; mkdir -p "${probe_dir}"
stage_save "${probe_dir}"
(
    cd "${probe_dir}"
    ulimit -s unlimited || true
    env -i HOME="$HOME" PATH="$PATH" AB_MODE=cpu OMP_NUM_THREADS="${OMP}" \
        "${YAMBO_BIN}" -F /dev/null > setup.log 2>&1 || true
) || true
NKPTS="$(grep -E 'K-points.*:.*[0-9]+' "${probe_dir}"/r-* 2>/dev/null | \
         grep -oE '[0-9]+' | head -1)"
[[ -z "${NKPTS}" ]] && NKPTS=$(grep -E 'IBZ Q/K' "${probe_dir}"/r-* 2>/dev/null | \
                               grep -oE '[0-9]+' | head -1)
[[ -z "${NKPTS}" ]] && NKPTS=1
echo "[probe] NKPTS=${NKPTS}"

# --- input decks ---------------------------------------------------------
# B1: IP-RPA (Chimod=IP, no kernel, dipoles only)
IP_RPA_IN_CONTENT=$(cat <<EOF
optics
chi
dipoles
Chimod= "IP"
% BndsRnXd
   1 | 50 |
%
% EnRngeXd
   0.00 | 10.00 | eV
%
% DmRngeXd
   0.10 | 0.10 | eV
%
ETStpsXd= 200
% LongDrXd
  1.0 | 0.0 | 0.0 |
%
EOF
)

# B2: GW-PPA (reduced bands, BG terminator per workflow notes)
GW_PPA_IN_CONTENT=$(cat <<EOF
gw0
ppa
dyson
HF_and_locXC
em1d
% GbndRnge
  1 | 30 |
%
% BndsRnXp
  1 | 30 |
%
NGsBlkXp= 2 Ry
% QPkrange
  1 | ${NKPTS} | ${VBM} | ${CBM} |
%
PPAPntXp= 27.21138 eV
XTermKind= "none"
GTermKind= "BG"
GTermEn= 40.0 eV
DysSolver= "n"
EOF
)

# --- run one Yambo stage in one mode -------------------------------------
run_stage() {
    local mode="$1" stage="$2" inp_content="$3"
    local base="${OUT_ROOT}/${mode}"
    local jlbl="${stage}_${mode}"
    local inp="${base}/${stage}.in"
    mkdir -p "${base}"
    [[ -d "${base}/SAVE" ]] || stage_save "${base}"
    printf "%s\n" "${inp_content}" > "${inp}"

    local AB_EXTRA=""
    case "${mode}" in
        cpu)  AB_EXTRA="AB_MODE=cpu" ;;
        gpu)  AB_EXTRA="AB_MODE=gpu AB_MIN_GPU_DIM=0" ;;
        auto) AB_EXTRA="AB_MODE=auto" ;;
    esac

    local TO
    TO="$(command -v gtimeout || command -v timeout || true)"

    echo "  [$(ts)] ${stage} | AB_MODE=${mode}"
    local start end wall rc=0
    start=$(date +%s)
    (
        cd "${base}"
        ulimit -s unlimited || true
        env -i HOME="$HOME" PATH="$PATH" \
            OMP_NUM_THREADS="${OMP}" \
            ${AB_EXTRA} \
            AB_PROFILE_FILE="${base}/gemm_profile_${stage}.txt" \
            ${TO:+${TO} ${YAMBO_TIMEOUT}} \
            mpirun -np "${NP}" "${YAMBO_BIN}" -F "$(basename "${inp}")" -J "${jlbl}" \
                   > "log_${stage}.txt" 2>&1
    ) || rc=$?
    end=$(date +%s); wall=$((end - start))

    local status="OK"
    if [[ ${rc} -ne 0 ]]; then
        if [[ ${rc} -eq 124 ]]; then status="TIMEOUT"; else status="FAIL(rc=${rc})"; fi
    fi

    # Yambo's report file: r-<jlbl>_<calc>
    local rep
    rep="$(ls "${base}/${jlbl}"/r-* 2>/dev/null | head -1 || true)"
    local yambo_wall="NA"
    if [[ -n "${rep}" ]]; then
        yambo_wall="$(grep -Eo '\[Time-Profile\]: [0-9.smhd]+' "${rep}" 2>/dev/null | \
                      tail -1 | awk '{print $2}')"
        [[ -z "${yambo_wall}" ]] && yambo_wall="$(grep -E 'Total.*Time' "${rep}" 2>/dev/null | \
                                                  tail -1 | awk '{print $NF}')"
    fi
    [[ -z "${yambo_wall}" ]] && yambo_wall="NA"

    {
        echo "system=${SYSTEM}"
        echo "stage=${stage}"
        echo "mode=${mode}"
        echo "status=${status}"
        echo "wall_seconds=${wall}"
        echo "yambo_time_profile=${yambo_wall}"
        echo "timestamp=$(ts)"
    } > "${base}/summary_${stage}.txt"

    local tag
    case "${status}" in
        OK)      tag="${C_GRN}OK${C_RST}" ;;
        TIMEOUT) tag="${C_YLW}TIMEOUT${C_RST}" ;;
        *)       tag="${C_RED}${status}${C_RST}" ;;
    esac
    printf "    %-6s %-6s  wall=%4ds  yambo=%-10s  [%s]\n" \
        "${stage}" "${mode}" "${wall}" "${yambo_wall}" "${tag}"
}

for mode in cpu gpu auto; do
    echo "${C_BLU}=== [$(ts)] Yambo ${SYSTEM} | AB_MODE=${mode} ===${C_RST}"
    run_stage "${mode}" "ip_rpa"  "${IP_RPA_IN_CONTENT}"
    run_stage "${mode}" "gw_ppa"  "${GW_PPA_IN_CONTENT}"
    # aggregate per-mode wall time (ip_rpa + gw_ppa)
    local_total=0
    for s in ip_rpa gw_ppa; do
        w=$(grep ^wall_seconds= "${OUT_ROOT}/${mode}/summary_${s}.txt" 2>/dev/null | cut -d= -f2)
        [[ -n "${w}" ]] && local_total=$((local_total + w))
    done
    echo "${local_total}" > "${OUT_ROOT}/${mode}/wall_seconds.txt"
done

echo ""
echo "${C_BLD}=== Summary: Yambo ${SYSTEM} ===${C_RST}"
printf "  %-6s  %-10s  %-10s  %-12s\n" "mode" "ip_rpa_s" "gw_ppa_s" "total_s"
for mode in cpu gpu auto; do
    ip=$(grep ^wall_seconds= "${OUT_ROOT}/${mode}/summary_ip_rpa.txt" 2>/dev/null | cut -d= -f2)
    gw=$(grep ^wall_seconds= "${OUT_ROOT}/${mode}/summary_gw_ppa.txt" 2>/dev/null | cut -d= -f2)
    tot=$(cat "${OUT_ROOT}/${mode}/wall_seconds.txt" 2>/dev/null || echo NA)
    printf "  %-6s  %-10s  %-10s  %-12s\n" "${mode}" "${ip:-NA}" "${gw:-NA}" "${tot:-NA}"
done
