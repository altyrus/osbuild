#!/bin/bash
#
# auto-test.sh - Automatically monitor build and run tests
#
# This script monitors the build, then automatically runs verification and QEMU tests
#

set -euo pipefail

BUILD_PID="$1"
IMAGE_PATTERN="rpi5-k8s-*.img"

echo "=========================================="
echo "Auto-Test Monitor"
echo "=========================================="
echo "Monitoring build process..."
echo ""

# Wait for build to complete
while kill -0 "$BUILD_PID" 2>/dev/null; do
    echo -n "."
    sleep 30
done

echo ""
echo "Build process completed!"
echo ""

# Find the built image
IMAGE_PATH=$(find test-output -name "${IMAGE_PATTERN}" -type f | head -1)

if [[ -z "$IMAGE_PATH" ]]; then
    echo "ERROR: No image found in test-output/"
    exit 1
fi

echo "Found image: $IMAGE_PATH"
echo ""

# Step 1: Verify cloud-init configuration
echo "=========================================="
echo "Step 1: Verifying cloud-init configuration"
echo "=========================================="
./scripts/docker-verify-cloudinit.sh "$IMAGE_PATH"
VERIFY_RESULT=$?

if [[ $VERIFY_RESULT -eq 0 ]]; then
    echo ""
    echo "✅ Cloud-init verification PASSED"
else
    echo ""
    echo "❌ Cloud-init verification FAILED"
    exit 1
fi

# Step 2: Test filesystem mount
echo ""
echo "=========================================="
echo "Step 2: Testing filesystem integrity"
echo "=========================================="

docker run --rm --privileged \
    -v "$(realpath $IMAGE_PATH):/test.img:ro" \
    ubuntu:22.04 \
    bash -c '
set -e
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq kpartx parted mount >/dev/null 2>&1

LOOP_DEVICE=$(losetup -f --show /test.img)
kpartx -av ${LOOP_DEVICE} >/dev/null

LOOP_NAME=$(basename ${LOOP_DEVICE})
ROOT_DEV="/dev/mapper/${LOOP_NAME}p2"

# Try to mount root partition
if mount ${ROOT_DEV} /mnt 2>/dev/null; then
    echo "✅ Filesystem mount successful"
    umount /mnt
    kpartx -dv ${LOOP_DEVICE} >/dev/null
    losetup -d ${LOOP_DEVICE}
    exit 0
else
    echo "❌ Filesystem mount FAILED"
    kpartx -dv ${LOOP_DEVICE} >/dev/null
    losetup -d ${LOOP_DEVICE}
    exit 1
fi
'

MOUNT_RESULT=$?

if [[ $MOUNT_RESULT -ne 0 ]]; then
    echo "❌ Filesystem integrity check FAILED"
    exit 1
fi

# Step 3: QEMU boot test
echo ""
echo "=========================================="
echo "Step 3: Testing boot in QEMU"
echo "=========================================="
./scripts/test-qemu-direct-boot.sh "$IMAGE_PATH" 300

echo ""
echo "=========================================="
echo "✅ All tests completed successfully!"
echo "=========================================="
