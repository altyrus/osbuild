#!/bin/bash
#
# docker-entrypoint.sh - Build entry point for Docker container
#
# This script runs inside the Docker container and executes the full
# image build process, mimicking the GitHub Actions workflow.
#

set -euo pipefail

echo "=========================================="
echo "OSBuild - Docker Build"
echo "=========================================="
echo "Kubernetes version: ${K8S_VERSION}"
echo "Image version: ${IMAGE_VERSION}"
echo "Base image: ${RASPIOS_VERSION}"
echo "=========================================="

cd /workspace

# Setup QEMU ARM64 emulation (required for chroot into ARM64 filesystem)
echo ""
echo "==> Setting up QEMU ARM64 emulation..."
if [[ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
    echo "QEMU ARM64 binfmt already registered"
else
    # Register ARM64 binfmt handler
    update-binfmts --enable qemu-aarch64 || {
        echo "Warning: Could not enable qemu-aarch64 via update-binfmts"
        echo "Attempting manual registration..."
        echo ':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static:F' > /proc/sys/fs/binfmt_misc/register || true
    }
fi
echo "✅ QEMU ARM64 emulation enabled"

# Step 1: Download base image if not cached
if [[ ! -f "image-build/cache/${RASPIOS_VERSION}.img.xz" ]]; then
    echo ""
    echo "==> Downloading Raspberry Pi OS base image..."
    mkdir -p image-build/cache
    cd image-build/cache
    wget -q --show-progress \
        "https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-10-02/${RASPIOS_VERSION}.img.xz"
    cd /workspace
    echo "✅ Download complete"
else
    echo "==> Using cached base image"
fi

# Step 2: Extract base image
echo ""
echo "==> Extracting base image..."
mkdir -p image-build/work
xz -dc "image-build/cache/${RASPIOS_VERSION}.img.xz" > image-build/work/base.img
ls -lh image-build/work/base.img

# Step 3: Expand image
echo ""
echo "==> Expanding image for customization..."
cd image-build/work

# Verify base.img exists
if [ ! -f "base.img" ]; then
    echo "ERROR: base.img not found"
    ls -la
    exit 1
fi

truncate -s +2G base.img
echo ", +" | sfdisk -N 2 base.img
sync  # Ensure partition table is written

# Setup loop device
LOOP_DEVICE=$(losetup -f --show base.img || {
    echo "ERROR: Failed to create loop device"
    echo "Checking loop devices:"
    losetup -a
    echo "Checking base.img:"
    ls -lh base.img
    exit 1
})
echo "Loop device: ${LOOP_DEVICE}"

# Use kpartx to create partition mappings (works in Docker)
kpartx -av ${LOOP_DEVICE}
sleep 1  # Give kernel time to create device mappings

# Get partition device names (kpartx creates /dev/mapper/ devices)
LOOP_NAME=$(basename ${LOOP_DEVICE})
BOOT_DEV="/dev/mapper/${LOOP_NAME}p1"
ROOT_DEV="/dev/mapper/${LOOP_NAME}p2"

# Verify partitions exist
if [ ! -b "${ROOT_DEV}" ]; then
    echo "ERROR: Partition ${ROOT_DEV} not found"
    ls -la /dev/mapper/
    kpartx -dv ${LOOP_DEVICE}
    losetup -d ${LOOP_DEVICE}
    exit 1
fi

echo "Boot partition: ${BOOT_DEV}"
echo "Root partition: ${ROOT_DEV}"

# Cleanup function
cleanup() {
    echo ""
    echo "==> Cleaning up..."
    umount /tmp/boot 2>/dev/null || true
    umount /tmp/root 2>/dev/null || true
    kpartx -dv ${LOOP_DEVICE} 2>/dev/null || true
    losetup -d ${LOOP_DEVICE} 2>/dev/null || true
}
trap cleanup EXIT

# Resize filesystem
e2fsck -f -y ${ROOT_DEV} || true
resize2fs ${ROOT_DEV}

cd /workspace

# Step 4: Mount partitions
echo ""
echo "==> Mounting partitions..."
mkdir -p /tmp/boot /tmp/root
mount ${ROOT_DEV} /tmp/root
mount ${BOOT_DEV} /tmp/boot

# Step 5: Install Kubernetes
echo ""
echo "==> Installing Kubernetes ${K8S_VERSION}..."
./image-build/scripts/01-install-k8s.sh /tmp/root "${K8S_VERSION}"

# Step 6: Install and configure cloud-init
echo ""
echo "==> Installing and configuring cloud-init..."
./image-build/scripts/02-install-cloudinit.sh /tmp/root

# Step 8: Cleanup and optimize
echo ""
echo "==> Cleaning up and optimizing..."
./image-build/scripts/04-cleanup.sh /tmp/root

# Step 9: Unmount and finalize
echo ""
echo "==> Unmounting partitions..."
# Sync all pending writes
sync
sleep 2

# Force unmount with retries
echo "Unmounting /tmp/boot..."
umount /tmp/boot || umount -l /tmp/boot || true
echo "Unmounting /tmp/root..."
umount /tmp/root || umount -l /tmp/root || true

# Final sync
sync
sleep 1

# Remove device mappings
echo "Removing device mappings..."
kpartx -dv ${LOOP_DEVICE}
sleep 1

# Remove loop device
echo "Removing loop device..."
losetup -d ${LOOP_DEVICE}

# Critical: Sync after loop device detach to flush all buffered writes
echo "Final sync after loop device detach..."
sync
sleep 3

trap - EXIT  # Remove trap

# Step 10: Shrink image (DISABLED for testing - image will be larger)
echo ""
echo "==> Skipping image shrinking (using unshrunk image for testing)..."

cd /workspace

# Step 11: Create output artifacts
echo ""
echo "==> Creating output artifacts..."
mkdir -p output

# Critical: Final sync before copying to ensure base.img is fully written
echo "Syncing filesystem before copy..."
sync
sleep 2

# Copy disk image
echo "Copying image file..."
cp image-build/work/base.img output/rpi5-k8s-${IMAGE_VERSION}.img

# Ensure copied file is synced
sync
echo "Image copy complete and synced"

# Generate checksum
cd output
sha256sum rpi5-k8s-${IMAGE_VERSION}.img > rpi5-k8s-${IMAGE_VERSION}.img.sha256

# Create metadata
cat > metadata.json <<EOF
{
  "version": "${IMAGE_VERSION}",
  "kubernetes_version": "${K8S_VERSION}",
  "base_image": "${RASPIOS_VERSION}",
  "build_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "build_type": "sdcard",
  "build_host": "$(hostname)"
}
EOF

cd /workspace

# Final output
echo ""
echo "=========================================="
echo "✅ Build completed successfully!"
echo "=========================================="
echo ""
echo "SD Card Image:"
ls -lh output/*.img
echo ""
echo "Flash to SD card with:"
echo "  sudo dd if=output/rpi5-k8s-${IMAGE_VERSION}.img of=/dev/sdX bs=4M status=progress conv=fsync"
echo ""
echo "Or use Raspberry Pi Imager and select 'Use custom' to flash the .img file"
echo "=========================================="
