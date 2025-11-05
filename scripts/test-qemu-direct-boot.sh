#!/bin/bash
#
# test-qemu-direct-boot.sh - Test ARM64 image with direct kernel boot
#
# This bypasses the Raspberry Pi bootloader by booting the kernel directly
#

set -euo pipefail

IMAGE_PATH="${1:?Image path required}"
TIMEOUT="${2:-600}"  # 10 minutes default

if [[ ! -f "${IMAGE_PATH}" ]]; then
    echo "ERROR: Image not found: ${IMAGE_PATH}"
    exit 1
fi

IMAGE_PATH=$(realpath "${IMAGE_PATH}")
IMAGE_NAME=$(basename "${IMAGE_PATH}")

echo "=========================================="
echo "QEMU Direct Kernel Boot Test"
echo "=========================================="
echo "Image: ${IMAGE_NAME}"
echo "Timeout: ${TIMEOUT}s"
echo "=========================================="
echo ""

# Run in Docker with direct kernel boot
docker run --rm --privileged \
    -v "${IMAGE_PATH}:/test.img:ro" \
    -e TIMEOUT="${TIMEOUT}" \
    ubuntu:22.04 \
    bash -c '
set -e

# Install required tools
export DEBIAN_FRONTEND=noninteractive
echo "Installing QEMU and tools..."
apt-get update -qq 2>&1 | grep -v "^Get:" || true
apt-get install -y -qq qemu-system-arm qemu-efi-aarch64 kpartx mount file 2>&1 | grep -v "^Selecting\|^Preparing\|^Unpacking" || true

echo "Mounting image to extract kernel..."

# Setup loop device
LOOP_DEVICE=$(losetup -f --show /test.img)
echo "Loop device: ${LOOP_DEVICE}"

# Create partition mappings
kpartx -av ${LOOP_DEVICE}
sleep 2

# Get partition names
LOOP_NAME=$(basename ${LOOP_DEVICE})
BOOT_DEV="/dev/mapper/${LOOP_NAME}p1"
ROOT_DEV="/dev/mapper/${LOOP_NAME}p2"

# Mount partitions
mkdir -p /mnt/boot /mnt/root
mount ${ROOT_DEV} /mnt/root || exit 1
mount ${BOOT_DEV} /mnt/boot || exit 1

# Find kernel and initrd
echo ""
echo "Looking for kernel and initrd..."
KERNEL=$(ls /mnt/boot/vmlinuz* /mnt/boot/kernel*.img 2>/dev/null | head -1 || true)
INITRD=$(ls /mnt/boot/initrd.img* /mnt/boot/initramfs* 2>/dev/null | head -1 || true)

# If not in boot, check root
if [[ -z "${KERNEL}" ]]; then
    KERNEL=$(ls /mnt/root/boot/vmlinuz* /mnt/root/boot/kernel*.img 2>/dev/null | head -1 || true)
fi
if [[ -z "${INITRD}" ]]; then
    INITRD=$(ls /mnt/root/boot/initrd.img* /mnt/root/boot/initramfs* 2>/dev/null | head -1 || true)
fi

if [[ -z "${KERNEL}" ]]; then
    echo "ERROR: Could not find kernel image"
    echo "Boot partition contents:"
    ls -la /mnt/boot/ | head -20
    echo ""
    echo "Root /boot contents:"
    ls -la /mnt/root/boot/ 2>/dev/null | head -20 || true
    umount /mnt/boot /mnt/root
    kpartx -dv ${LOOP_DEVICE}
    losetup -d ${LOOP_DEVICE}
    exit 1
fi

echo "Kernel: ${KERNEL}"
echo "Initrd: ${INITRD}"

# Copy kernel and initrd to /tmp
echo "Extracting kernel and initrd..."
cp "${KERNEL}" /tmp/vmlinuz
if [[ -n "${INITRD}" ]]; then
    cp "${INITRD}" /tmp/initrd.img
    HAS_INITRD=true
else
    HAS_INITRD=false
    echo "No initrd found, will boot without it"
fi

# Get root device UUID
ROOT_UUID=$(blkid ${ROOT_DEV} -s UUID -o value)
echo "Root UUID: ${ROOT_UUID}"

# Copy image for read-write access
echo "Copying image for read-write boot..."
cp /test.img /tmp/test-rw.img

# Unmount
umount /mnt/boot
umount /mnt/root
kpartx -dv ${LOOP_DEVICE}
losetup -d ${LOOP_DEVICE}

echo ""
echo "=========================================="
echo "Booting with direct kernel boot..."
echo "=========================================="
echo ""

# Build kernel command line
CMDLINE="console=ttyAMA0 root=UUID=${ROOT_UUID} rootfstype=ext4 rw rootwait"

# Boot with direct kernel
if [[ "${HAS_INITRD}" == "true" ]]; then
    timeout ${TIMEOUT} qemu-system-aarch64 \
        -M virt \
        -cpu cortex-a72 \
        -m 2048 \
        -nographic \
        -kernel /tmp/vmlinuz \
        -initrd /tmp/initrd.img \
        -append "${CMDLINE}" \
        -drive if=none,file=/tmp/test-rw.img,id=hd0,format=raw \
        -device virtio-blk-device,drive=hd0 \
        -netdev user,id=net0 \
        -device virtio-net-device,netdev=net0 \
        2>&1 || true
else
    timeout ${TIMEOUT} qemu-system-aarch64 \
        -M virt \
        -cpu cortex-a72 \
        -m 2048 \
        -nographic \
        -kernel /tmp/vmlinuz \
        -append "${CMDLINE}" \
        -drive if=none,file=/tmp/test-rw.img,id=hd0,format=raw \
        -device virtio-blk-device,drive=hd0 \
        -netdev user,id=net0 \
        -device virtio-net-device,netdev=net0 \
        2>&1 || true
fi

echo ""
echo "=========================================="
echo "Boot test completed"
echo "=========================================="
'

echo ""
echo "Test complete."
