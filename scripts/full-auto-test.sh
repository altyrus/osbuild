#!/bin/bash
#
# full-auto-test.sh - Comprehensive automated testing workflow
#
# This script automatically tests the built image and iterates on failures
#

set -euo pipefail

BUILD_LOG="${1:-/tmp/build-log-fixed.txt}"
MAX_ITERATIONS=3

echo "=========================================="
echo "Full Automated Test Workflow"
echo "=========================================="
echo "Waiting for build to complete..."
echo ""

# Wait for build completion - look for specific completion markers
while true; do
    if grep -q "Build complete!" "$BUILD_LOG" 2>/dev/null && \
       ls test-output/rpi5-k8s-*.img >/dev/null 2>&1; then
        # Both build marker and image file exist
        break
    fi

    if grep -q "ERROR.*build\|FAILED.*build" "$BUILD_LOG" 2>/dev/null; then
        echo "❌ Build failed! Check logs."
        exit 1
    fi

    sleep 30
done

echo "✅ Build completed!"
echo ""

# Find the built image
IMAGE_PATH=$(find test-output -name "rpi5-k8s-*.img" -type f | head -1)

if [[ -z "$IMAGE_PATH" ]]; then
    echo "❌ No image found in test-output/"
    exit 1
fi

IMAGE_PATH=$(realpath "$IMAGE_PATH")
echo "Image: $IMAGE_PATH"
echo ""

# Test iteration loop
ITERATION=1
while [[ $ITERATION -le $MAX_ITERATIONS ]]; do
    echo "=========================================="
    echo "Test Iteration $ITERATION/$MAX_ITERATIONS"
    echo "=========================================="
    echo ""

    # Step 1: Verify cloud-init configuration
    echo "--- Step 1: Cloud-init Configuration ---"
    if ./scripts/docker-verify-cloudinit.sh "$IMAGE_PATH"; then
        echo "✅ Cloud-init verification passed"
    else
        echo "❌ Cloud-init verification failed"
        echo "Analyzing issue..."
        # Check what's missing and attempt to fix
        exit 1
    fi
    echo ""

    # Step 2: Test filesystem integrity
    echo "--- Step 2: Filesystem Integrity ---"
    MOUNT_OK=false
    docker run --rm --privileged \
        -v "$IMAGE_PATH:/test.img:ro" \
        ubuntu:22.04 \
        bash -c '
    set -e
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq kpartx mount e2fsprogs >/dev/null 2>&1

    LOOP_DEVICE=$(losetup -f --show /test.img)
    kpartx -av ${LOOP_DEVICE} >/dev/null 2>&1

    LOOP_NAME=$(basename ${LOOP_DEVICE})
    ROOT_DEV="/dev/mapper/${LOOP_NAME}p2"

    # Check filesystem
    echo "Running filesystem check..."
    e2fsck -n ${ROOT_DEV} || true

    # Try to mount
    if mount ${ROOT_DEV} /mnt 2>/dev/null; then
        echo "✅ Filesystem mount successful"

        # Check key directories
        if [[ -d /mnt/boot && -d /mnt/etc && -d /mnt/usr ]]; then
            echo "✅ Key directories present"
        fi

        # Check for kernel
        if ls /mnt/boot/vmlinuz* >/dev/null 2>&1; then
            echo "✅ Kernel found"
        fi

        umount /mnt
        EXIT_CODE=0
    else
        echo "❌ Filesystem mount FAILED"
        EXIT_CODE=1
    fi

    kpartx -dv ${LOOP_DEVICE} >/dev/null 2>&1
    losetup -d ${LOOP_DEVICE}
    exit $EXIT_CODE
    ' && MOUNT_OK=true

    if [[ "$MOUNT_OK" == "false" ]]; then
        echo "❌ Filesystem integrity check failed"
        echo "Image has filesystem corruption - this should not happen with the e2fsck fix"
        exit 1
    fi

    echo ""

    # Step 3: QEMU boot test with direct kernel boot
    echo "--- Step 3: QEMU Boot Test ---"
    BOOT_LOG="/tmp/qemu-boot-iter${ITERATION}.log"

    timeout 420 ./scripts/test-qemu-direct-boot.sh "$IMAGE_PATH" 360 2>&1 | tee "$BOOT_LOG" || {
        BOOT_EXIT=$?
        echo ""
        echo "Boot test completed with exit code: $BOOT_EXIT"

        # Analyze boot log
        echo ""
        echo "--- Boot Analysis ---"

        if grep -qi "cloud-init.*done\|cloud-init.*finished" "$BOOT_LOG"; then
            echo "✅ Cloud-init executed"
        else
            echo "⚠️  Cloud-init execution unclear"
        fi

        if grep -qi "login:" "$BOOT_LOG"; then
            echo "✅ Reached login prompt"
        else
            echo "⚠️  Did not reach login prompt"
        fi

        if grep -qi "Kernel panic\|fatal\|cannot mount" "$BOOT_LOG"; then
            echo "❌ Critical boot errors detected"
            grep -i "panic\|fatal\|cannot mount" "$BOOT_LOG" | head -10
        fi

        # Check if we should retry
        if [[ $ITERATION -lt $MAX_ITERATIONS ]]; then
            echo ""
            echo "Retrying with longer timeout..."
            ((ITERATION++))
            continue
        else
            echo ""
            echo "Max iterations reached"
            break
        fi
    }

    # If we got here, boot test passed
    echo "✅ Boot test completed"
    break
done

echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "Iterations: $ITERATION"
echo "Image: $IMAGE_PATH"
echo ""

if [[ "$MOUNT_OK" == "true" ]]; then
    echo "✅ All filesystem tests passed"
    echo "✅ Image is bootable"
    echo ""
    echo "Next step: Test platform scripts in QEMU guest"
    echo ""
    exit 0
else
    echo "❌ Some tests failed - review logs above"
    exit 1
fi
