#!/usr/bin/env bash
# Deep filesystem recon: finds QE 7.5 source, existing QE+Yambo builds,
# their configure logs, apple-bottom dylib, and QE input decks.
# Run on the Mac, paste the output back — no benchmarks until paths are known.
set -uo pipefail

header() { printf "\n========== %s ==========\n" "$*"; }

header "apple-bottom dylib"
find "$HOME/Dev/arm/metal-algos" "$HOME/apple-bottom" \
     -name "libapplebottom*.dylib" -type f 2>/dev/null | head -10

header "apple-bottom headers"
find "$HOME/Dev/arm/metal-algos/include" "$HOME/apple-bottom/include" \
     -name "*.h" 2>/dev/null | head -5

header "QE source trees (looking for version 7.5)"
for root in "$HOME/qe-test" "$HOME/Dev/qe-test" "$HOME" "$HOME/Dev"; do
    [[ -d "$root" ]] || continue
    find "$root" -maxdepth 4 -type d \( -name "q-e*" -o -name "qe-*" -o -name "quantum-espresso*" \) 2>/dev/null | head -5
done
echo ""
echo "  Looking for 'version 7.5' in any configure scripts:"
find "$HOME/qe-test" "$HOME/Dev/qe-test" "$HOME/Dev" -maxdepth 4 -name "configure" -type f 2>/dev/null | while read -r c; do
    if grep -q "7\.5" "$c" 2>/dev/null; then
        echo "    ${c}"
    fi
done | head -10

header "QE existing builds (pw.x locations)"
find "$HOME" -maxdepth 6 -name "pw.x" -type f 2>/dev/null | head -10

header "QE existing make.inc / config.log"
find "$HOME/qe-test" "$HOME/Dev/qe-test" -name "make.inc" -o -name "config.log" 2>/dev/null | head -10

header "QE input decks (.in files, anywhere under ~/qe-test)"
find "$HOME/qe-test" "$HOME/Dev/qe-test" -maxdepth 6 -name "*.in" -type f 2>/dev/null | head -30

header "Does any existing QE source have cegterg.f90 modified for ab_zgemm?"
find "$HOME" -maxdepth 6 -name "cegterg.f90" -type f 2>/dev/null | while read -r f; do
    if grep -q "ab_zgemm" "$f" 2>/dev/null; then
        echo "  MODIFIED: ${f}"
    else
        echo "  stock:    ${f}"
    fi
done | head -10

header "Yambo source trees"
for root in "$HOME/yambo-build" "$HOME/Dev/yambo-build" "$HOME"; do
    [[ -d "$root" ]] || continue
    find "$root" -maxdepth 4 -type d -name "yambo-*" 2>/dev/null | head -5
done
echo ""
echo "  Any mod_wrapper.F modified for ab_zgemm?"
find "$HOME" -maxdepth 7 -name "mod_wrapper*.F" -type f 2>/dev/null | while read -r f; do
    if grep -q "ab_zgemm" "$f" 2>/dev/null; then
        echo "    MODIFIED: ${f}"
    else
        echo "    stock:    ${f}"
    fi
done | head -10

header "Yambo existing builds (yambo binary locations)"
find "$HOME" -maxdepth 6 -name "yambo" -type f -perm -u+x 2>/dev/null | head -10

header "Yambo configure artifacts"
find "$HOME/yambo-build" "$HOME/Dev/yambo-build" -name "config.log" -o -name "config.status" 2>/dev/null | head -10

header "GaAs Yambo template contents (subdir walk)"
if [[ -d "$HOME/Dev/yambo-build/gaas-bse" ]]; then
    find "$HOME/Dev/yambo-build/gaas-bse" -maxdepth 3 -type f \( -name "*.in" -o -name "SAVE" -o -name "*.DB*" \) 2>/dev/null | head -30
    echo ""
    echo "  gw/ contents:"
    ls "$HOME/Dev/yambo-build/gaas-bse/gw" 2>/dev/null | head -20
    echo "  bse/ contents:"
    ls "$HOME/Dev/yambo-build/gaas-bse/bse" 2>/dev/null | head -20
fi

header "Done"
echo "Paste the output back so config.sh + rebuild scripts can be generated."
