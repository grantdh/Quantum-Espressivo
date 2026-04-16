#!/usr/bin/env bash
# Pre-flight diagnostic: show what the harness will/won't find on disk,
# and dump full otool output for QE and Yambo binaries.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/config.sh"

echo "================ apple-bottom benchmark diagnostic ================"
echo ""
echo "PW_BIN    = ${PW_BIN}"
echo "YAMBO_BIN = ${YAMBO_BIN}"
echo "NP=${NP}  OMP=${OMP}"
echo ""

echo "---- Binary existence ----"
for b in "${PW_BIN}" "${YAMBO_BIN}"; do
    if [[ -x "${b}" ]]; then echo "  OK    ${b}"
    else                      echo "  MISS  ${b}"
    fi
done
echo ""

echo "---- libapplebottom linkage ----"
check_applebottom_link "${PW_BIN}"
check_applebottom_link "${YAMBO_BIN}"
echo ""

echo "---- QE input search roots ----"
for r in "${QE_SEARCH_ROOTS[@]}"; do
    if [[ -d "${r}" ]]; then echo "  EXISTS  ${r}"
        ls -1 "${r}" 2>/dev/null | head -8 | sed 's/^/            /'
    else                     echo "  missing ${r}"
    fi
done
echo ""

echo "---- QE per-system resolution ----"
for sys in si8 si16 si32 si64 si64_4k si128; do
    if d="$(qe_input_dir "${sys}" 2>/dev/null)"; then
        echo "  ${sys}  -> ${d}"
    else
        echo "  ${sys}  NOT FOUND"
    fi
done
echo ""

echo "---- Yambo templates ----"
for sys in gaas si; do
    if d="$(yambo_template_dir "${sys}" 2>/dev/null)"; then
        echo "  ${sys}  -> ${d}"
        ls "${d}" 2>/dev/null | head -6 | sed 's/^/          /'
    else
        echo "  ${sys}  NOT FOUND"
    fi
done
echo ""

echo "---- AB_MODE runtime smoke test ----"
# A tiny GEMM through dlopen to confirm AB_MODE is picked up
AB_LIB="${AB_LIB:-${HOME}/Dev/arm/metal-algos/build/libapplebottom.dylib}"
if [[ -f "${AB_LIB}" ]]; then
    echo "  apple-bottom dylib: ${AB_LIB}"
    otool -D "${AB_LIB}" 2>/dev/null | tail -1
else
    echo "  apple-bottom dylib not found at ${AB_LIB}"
    echo "  (set AB_LIB=/path/to/libapplebottom.dylib)"
fi
echo ""
echo "=================================================================="
