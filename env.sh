#!/bin/bash
# Source this file to set up Espressivo environment

ESPRESSIVO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export APPLE_BOTTOM_DIR="$ESPRESSIVO_ROOT/deps/apple-bottom"
export LIBRARY_PATH="$APPLE_BOTTOM_DIR/lib:$LIBRARY_PATH"
export CPATH="$APPLE_BOTTOM_DIR/include:$CPATH"
export PKG_CONFIG_PATH="$APPLE_BOTTOM_DIR/lib/pkgconfig:$PKG_CONFIG_PATH"

echo "Espressivo environment configured:"
echo "  APPLE_BOTTOM_DIR: $APPLE_BOTTOM_DIR"
echo "  Use 'pkg-config --libs applebottom' to get linker flags"
