#!/bin/bash
# Source this file to compile and link against the apple-bottom that setup-apple-bottom.sh built.

ESPRESSIVO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export APPLE_BOTTOM_DIR="${APPLE_BOTTOM_DIR:-$ESPRESSIVO_ROOT/deps/apple-bottom}"
export LIBRARY_PATH="$APPLE_BOTTOM_DIR/build${LIBRARY_PATH:+:$LIBRARY_PATH}"
export CPATH="$APPLE_BOTTOM_DIR/include${CPATH:+:$CPATH}"

echo "Espressivo environment configured:"
echo "  APPLE_BOTTOM_DIR: $APPLE_BOTTOM_DIR"
echo "  Link with: -L\$APPLE_BOTTOM_DIR/build -Wl,-rpath,\$APPLE_BOTTOM_DIR/build -lapplebottom"
