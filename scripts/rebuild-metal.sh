#!/bin/bash
# rebuild-metal.sh — rebuild apple-bottom and relink pw.x against it
#
# Usage:
#   ./scripts/rebuild-metal.sh                         # deps/apple-bottom
#   ./scripts/rebuild-metal.sh --ab-dev /path/to/repo  # an apple-bottom checkout of your own
#   ./scripts/rebuild-metal.sh --skip-qe               # only rebuild the library
#
# Rebuilds libapplebottom.dylib in the checkout, runs its tests, and relinks
# deps/qe/build-metal/bin/pw.x against it (a full build-qe-metal.sh if there is no build yet).
# pw.x loads the library through its rpath, so it needs no relink when it already links
# against that checkout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
SKIP_QE=false

while [ $# -gt 0 ]; do
    case $1 in
        --ab-dev)    shift; APPLE_BOTTOM_DIR="$1" ;;
        --ab-dev=*)  APPLE_BOTTOM_DIR="${1#*=}" ;;
        --skip-qe)   SKIP_QE=true ;;
        -h|--help)
            echo "Usage: $0 [--ab-dev /path/to/apple-bottom] [--skip-qe]"
            exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
    shift
done
APPLE_BOTTOM_DIR="$(cd "$APPLE_BOTTOM_DIR" && pwd)"
export APPLE_BOTTOM_DIR
BUILD_DIR="$QE_DIR/build-metal"

echo "=== Rebuilding apple-bottom in $APPLE_BOTTOM_DIR ($(git_desc "$APPLE_BOTTOM_DIR")) ==="
build_apple_bottom

if [ "$SKIP_QE" = true ]; then
    echo "Done: $APPLE_BOTTOM_DIR/build/libapplebottom.dylib"
    exit 0
fi
if [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
    echo "No QE build in $BUILD_DIR yet: running build-qe-metal.sh"
    exec "$SCRIPT_DIR/build-qe-metal.sh"
fi

echo ""
if grep -qxF "CMAKE_EXE_LINKER_FLAGS:STRING=$(ab_link_flags)" "$BUILD_DIR/CMakeCache.txt"; then
    echo "=== pw.x already links against $APPLE_BOTTOM_DIR/build: no relink needed ==="
else
    echo "=== Relinking pw.x against $APPLE_BOTTOM_DIR/build ==="
    rm -f "$BUILD_DIR/bin/pw.x"
    build_pw "$BUILD_DIR" -DCMAKE_EXE_LINKER_FLAGS="$(ab_link_flags)" || exit 1
fi
check_gemm_bindings "$BUILD_DIR/bin/pw.x" || exit 1
write_provenance "$BUILD_DIR"

echo ""
echo "Ready: $BUILD_DIR/bin/pw.x"
echo "Next: ./scripts/validate.sh"
