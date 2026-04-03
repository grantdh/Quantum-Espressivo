#!/bin/bash
# Setup apple-bottom dependency for Espressivo

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESPRESSIVO_ROOT="$(dirname "$SCRIPT_DIR")"
APPLE_BOTTOM_DIR="$ESPRESSIVO_ROOT/deps/apple-bottom"

echo "Setting up apple-bottom for Espressivo..."

# Check if already installed
if [ -f "$APPLE_BOTTOM_DIR/lib/libapplebottom.a" ]; then
    echo "apple-bottom already installed at $APPLE_BOTTOM_DIR"
    echo "To reinstall, remove $APPLE_BOTTOM_DIR first"
    exit 0
fi

# Create deps directory
mkdir -p "$ESPRESSIVO_ROOT/deps"
cd "$ESPRESSIVO_ROOT/deps"

# Clone apple-bottom
if [ ! -d "$APPLE_BOTTOM_DIR" ]; then
    echo "Cloning apple-bottom..."
    git clone https://github.com/grantdh/apple-bottom.git
else
    echo "apple-bottom directory exists, updating..."
    cd "$APPLE_BOTTOM_DIR"
    git pull
fi

cd "$APPLE_BOTTOM_DIR"

# Build apple-bottom
echo "Building apple-bottom..."
make clean
make -j$(sysctl -n hw.logicalcpu)

# Run tests to verify
echo "Running apple-bottom tests..."
make test

# Create environment setup script
cat > "$ESPRESSIVO_ROOT/env.sh" << 'EOF'
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
EOF

chmod +x "$ESPRESSIVO_ROOT/env.sh"

echo ""
echo "apple-bottom successfully installed!"
echo ""
echo "To use in your shell session:"
echo "  source $ESPRESSIVO_ROOT/env.sh"
echo ""
echo "Library location: $APPLE_BOTTOM_DIR/lib/libapplebottom.a"
echo "Headers location: $APPLE_BOTTOM_DIR/include/"