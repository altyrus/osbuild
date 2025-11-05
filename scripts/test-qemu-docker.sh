#!/bin/bash
#
# test-qemu-docker.sh - Test ARM64 image in QEMU via Docker
#
# This boots the Raspberry Pi OS ARM64 image in QEMU to verify cloud-init
# runs correctly without prompting for username.
#

set -euo pipefail

IMAGE_PATH="${1:?Image path required}"
TIMEOUT="${2:-300}"  # 5 minutes default

if [[ ! -f "${IMAGE_PATH}" ]]; then
    echo "ERROR: Image not found: ${IMAGE_PATH}"
    exit 1
fi

IMAGE_PATH=$(realpath "${IMAGE_PATH}")
IMAGE_NAME=$(basename "${IMAGE_PATH}")

echo "=========================================="
echo "QEMU ARM64 Boot Test"
echo "=========================================="
echo "Image: ${IMAGE_NAME}"
echo "Timeout: ${TIMEOUT}s"
echo "=========================================="
echo ""

# Create a test directory with the image
TEST_DIR="/tmp/qemu-test-$$"
mkdir -p "${TEST_DIR}"

# Copy image to test dir (QEMU needs write access)
echo "Copying image to test directory (this may take a moment)..."
cp "${IMAGE_PATH}" "${TEST_DIR}/test.img"

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    rm -rf "${TEST_DIR}"
}
trap cleanup EXIT

echo "Starting QEMU in Docker..."
echo "Monitoring for cloud-init execution..."
echo ""
echo "=========================================="

# Run QEMU in Docker with monitoring
docker run --rm --privileged \
    -v "${TEST_DIR}:/test:rw" \
    -e TIMEOUT="${TIMEOUT}" \
    ubuntu:22.04 \
    bash -c '
set -e

# Install QEMU and dependencies
export DEBIAN_FRONTEND=noninteractive
echo "Installing QEMU ARM64 emulation..."
apt-get update -qq 2>&1 | grep -v "^Get:" || true
apt-get install -y -qq qemu-system-arm qemu-efi-aarch64 2>&1 | grep -v "^Selecting\|^Preparing\|^Unpacking\|^Setting" || true

echo "QEMU installation complete"
echo ""
echo "=========================================="
echo "Booting ARM64 image..."
echo "=========================================="
echo ""

# Create a log file for boot output
LOG_FILE="/test/boot.log"

# Boot with serial console - capture output
timeout ${TIMEOUT} qemu-system-aarch64 \
    -M virt \
    -cpu cortex-a72 \
    -m 2048 \
    -nographic \
    -drive if=none,file=/test/test.img,id=hd0,format=raw \
    -device virtio-blk-device,drive=hd0 \
    -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
    -serial mon:stdio \
    2>&1 | tee ${LOG_FILE} || {
        EXIT_CODE=$?
        echo ""
        echo "=========================================="
        if [ $EXIT_CODE -eq 124 ]; then
            echo "Boot test timed out (${TIMEOUT}s)"
        else
            echo "QEMU exited with code: $EXIT_CODE"
        fi
        echo "=========================================="

        # Analyze the log
        echo ""
        echo "Boot Analysis:"
        echo "=========================================="

        # Check for cloud-init
        if grep -q "cloud-init" ${LOG_FILE}; then
            echo "✅ Cloud-init was mentioned in boot log"
            grep -i "cloud-init" ${LOG_FILE} | head -5
        else
            echo "❌ Cloud-init not found in boot log"
        fi

        echo ""

        # Check for user prompts
        if grep -qi "login:" ${LOG_FILE}; then
            echo "✅ Reached login prompt"
            # Check what comes before login
            grep -B5 "login:" ${LOG_FILE} | tail -10
        else
            echo "⚠️  Did not reach login prompt"
        fi

        echo ""

        # Check for username prompts (should NOT appear)
        if grep -qi "enter.*username\|create.*user\|new.*user" ${LOG_FILE}; then
            echo "❌ FAILED: System prompted for username creation"
            grep -i "enter.*username\|create.*user\|new.*user" ${LOG_FILE}
        else
            echo "✅ No username creation prompts detected"
        fi

        echo ""

        # Check for errors
        if grep -qi "error\|failed\|fatal" ${LOG_FILE} | head -10; then
            echo "⚠️  Errors detected in boot:"
            grep -i "error\|failed\|fatal" ${LOG_FILE} | head -10
        fi

        echo "=========================================="
        echo ""
        echo "Full boot log saved to: ${LOG_FILE}"

        exit 0
    }
'

echo ""
echo "Test complete. Check output above for cloud-init execution."
