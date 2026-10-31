#!/bin/bash
# setup-apple-bottom.sh — fetch and build the apple-bottom release pinned in common.sh
#
# Usage:
#   ./scripts/setup-apple-bottom.sh
#
# Produces deps/apple-bottom/build/libapplebottom.dylib and runs apple-bottom's tests, which
# use the GPU. With APPLE_BOTTOM_DIR set, it builds that checkout in place instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

if [ -f "$APPLE_BOTTOM_DIR/build/libapplebottom.dylib" ]; then
    echo "apple-bottom is already built in $APPLE_BOTTOM_DIR ($(git_desc "$APPLE_BOTTOM_DIR"))."
    echo "Remove $APPLE_BOTTOM_DIR/build to rebuild it."
    exit 0
fi

fetch_commit "$APPLE_BOTTOM_DIR" "$APPLE_BOTTOM_URL" "$APPLE_BOTTOM_COMMIT"

echo "Building apple-bottom and running its tests..."
build_apple_bottom

echo ""
echo "apple-bottom built: $APPLE_BOTTOM_DIR/build/libapplebottom.dylib"
echo "To compile against it in your shell: source $ESPRESSIVO_ROOT/env.sh"
