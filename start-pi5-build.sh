#!/bin/bash
#
# Clean start script for Pi5 zero-touch build
#
# This script cleans up any previous build attempts and starts fresh
#

set -e

echo "=========================================="
echo "Pi5 Zero-Touch Build - Clean Start"
echo "=========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")"

echo "Step 1: Cleaning up previous build artifacts..."

# Detach loop devices
if losetup | grep -q "work/pi5/base.img"; then
    LOOP_DEV=$(losetup | grep "work/pi5/base.img" | awk '{print $1}')
    echo "  Detaching loop device: $LOOP_DEV"
    losetup -d "$LOOP_DEV" || true
fi

# Remove old work files
if [ -f "work/pi5/base.img" ]; then
    echo "  Removing old base.img..."
    rm -f work/pi5/base.img
fi

# Remove lock files
rm -f /tmp/osbuild-*.lock

# Clean up any stale kpartx mappings
kpartx -dv /dev/loop* 2>/dev/null || true

echo "  Cleanup complete!"
echo ""

echo "Step 2: Starting Pi5 zero-touch build..."
echo ""

# Start the build
BUILD_PLATFORM=pi5 ./build-zerotouch.sh

echo ""
echo "=========================================="
echo "Build Complete!"
echo "=========================================="
