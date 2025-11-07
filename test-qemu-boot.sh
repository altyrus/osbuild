#!/bin/bash
#
# test-qemu-boot.sh - Boot Raspberry Pi image in QEMU and test cloud-init
#
# This script boots the Raspberry Pi OS image using QEMU with ARM64 emulation
# and monitors cloud-init execution to verify automatic provisioning works.
#

set -euo pipefail

# Configuration
IMAGE_FILE="${1:-test-output/rpi5-k8s-docker-20251104-212733.img}"
KERNEL_FILE="${2:-/tmp/vmlinuz-rpi}"
INITRD_FILE="${3:-/tmp/initrd-rpi.img}"
ROOT_UUID="56f80fa2-e005-4cca-86e6-19da1069914d"

echo "==========================================="
echo "QEMU ARM64 Boot Test"
echo "==========================================="
echo "Image: ${IMAGE_FILE}"
echo "Kernel: ${KERNEL_FILE}"
echo "Initrd: ${INITRD_FILE}"
echo "Root UUID: ${ROOT_UUID}"
echo "==========================================="
echo ""

# Check files exist
if [[ ! -f "${IMAGE_FILE}" ]]; then
    echo "ERROR: Image file not found: ${IMAGE_FILE}"
    exit 1
fi

if [[ ! -f "${KERNEL_FILE}" ]]; then
    echo "ERROR: Kernel file not found: ${KERNEL_FILE}"
    exit 1
fi

if [[ ! -f "${INITRD_FILE}" ]]; then
    echo "ERROR: Initrd file not found: ${INITRD_FILE}"
    exit 1
fi

# Check if QEMU is installed
if ! command -v qemu-system-aarch64 &> /dev/null; then
    echo "ERROR: qemu-system-aarch64 not found"
    echo "Install with: sudo apt-get install qemu-system-arm"
    exit 1
fi

echo "Starting QEMU boot test..."
echo "Press Ctrl-A then X to exit QEMU"
echo "Watch for cloud-init messages during boot"
echo ""
echo "Expected cloud-init outputs:"
echo "  - Cloud-init v. 22.4.2 running 'init'"
echo "  - Cloud-init v. 22.4.2 running 'modules:config'"
echo "  - Cloud-init v. 22.4.2 running 'modules:final'"
echo "  - 'Cloud-init has finished configuring...'"
echo ""
sleep 3

# Boot with QEMU
# Using virtio for better performance
# -nographic for serial console output
# -m 2048 for 2GB RAM (Pi 5 has 4/8GB, but 2GB enough for testing)
# -smp 2 for 2 CPU cores
exec qemu-system-aarch64 \
    -M virt \
    -cpu cortex-a72 \
    -m 2048 \
    -smp 2 \
    -nographic \
    -kernel "${KERNEL_FILE}" \
    -initrd "${INITRD_FILE}" \
    -append "console=ttyAMA0 root=UUID=${ROOT_UUID} rootfstype=ext4 rw rootwait panic=1 init=/lib/systemd/systemd" \
    -drive if=none,file="${IMAGE_FILE}",id=hd0,format=raw \
    -device virtio-blk-device,drive=hd0 \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net-device,netdev=net0
