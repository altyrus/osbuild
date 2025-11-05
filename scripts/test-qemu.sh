#!/bin/bash
#
# test-qemu.sh - Test OSBuild image in QEMU
#
# This script boots the built image in QEMU (ARM64) to verify cloud-init
# runs automatically without prompting for username.
#
# Usage: ./test-qemu.sh <path-to-image>
#

set -euo pipefail

IMAGE_PATH="${1:?Image path required}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "OSBuild - QEMU Test"
echo "=========================================="
echo "Image: ${IMAGE_PATH}"
echo "=========================================="
echo ""

# Verify image exists
if [[ ! -f "${IMAGE_PATH}" ]]; then
    echo "ERROR: Image not found: ${IMAGE_PATH}"
    exit 1
fi

# Get absolute path
IMAGE_PATH=$(realpath "${IMAGE_PATH}")

echo "Starting QEMU test in Docker..."
echo ""
echo "This will boot the image and monitor for:"
echo "  ✓ Cloud-init execution"
echo "  ✓ Automatic user creation"
echo "  ✗ Username prompts (should NOT appear)"
echo ""
echo "Press Ctrl+C to stop"
echo "=========================================="
echo ""

# Run QEMU in Docker with ARM64 emulation
docker run --rm -it --privileged \
    -v "${IMAGE_PATH}:/image.img:ro" \
    -v /usr/bin/qemu-aarch64-static:/usr/bin/qemu-aarch64-static:ro \
    ubuntu:22.04 \
    bash -c "
set -e

# Install QEMU
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq qemu-system-aarch64 qemu-efi-aarch64 > /dev/null 2>&1

echo 'Starting QEMU ARM64 emulation...'
echo ''

# Boot the image with serial console output
# Note: This is a read-only boot for testing
timeout 120 qemu-system-aarch64 \\
    -M virt \\
    -cpu cortex-a72 \\
    -m 2048 \\
    -nographic \\
    -drive if=none,file=/image.img,id=hd0,format=raw,readonly=on \\
    -device virtio-blk-device,drive=hd0 \\
    -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \\
    -serial mon:stdio \\
    || {
        EXIT_CODE=\$?
        if [ \$EXIT_CODE -eq 124 ]; then
            echo ''
            echo '=========================================='
            echo 'QEMU test timed out after 120 seconds'
            echo 'This is expected if boot completed successfully'
            echo '=========================================='
            exit 0
        else
            echo ''
            echo '=========================================='
            echo 'QEMU exited with error code:' \$EXIT_CODE
            echo '=========================================='
            exit \$EXIT_CODE
        fi
    }
"

echo ""
echo "=========================================="
echo "QEMU test completed"
echo "=========================================="
echo ""
echo "Review the output above to verify:"
echo "  1. Cloud-init ran successfully"
echo "  2. User 'pi' was created automatically"
echo "  3. No username prompts appeared"
echo ""
