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
if [[ ! -f "cache/${RASPIOS_VERSION}.img.xz" ]]; then
    echo ""
    echo "==> Downloading Raspberry Pi OS base image..."
    mkdir -p cache
    cd cache
    if ! wget -q --show-progress \
        "https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-10-02/${RASPIOS_VERSION}.img.xz"; then
        echo "ERROR: Failed to download base image"
        exit 1
    fi

    # Verify download
    if [ ! -s "${RASPIOS_VERSION}.img.xz" ]; then
        echo "ERROR: Downloaded file is empty"
        rm -f "${RASPIOS_VERSION}.img.xz"
        exit 1
    fi

    cd /workspace
    echo "✅ Download complete"
else
    echo "==> Using cached base image"
fi

# Step 2: Extract and resize base image
echo ""
echo "==> Extracting base image..."
mkdir -p work
if ! xz -dc "cache/${RASPIOS_VERSION}.img.xz" > work/base.img; then
    echo "ERROR: Failed to extract base image"
    rm -f work/base.img
    exit 1
fi

# Verify extraction
if [ ! -s "work/base.img" ]; then
    echo "ERROR: Extracted image is empty or missing"
    exit 1
fi

echo "Original image size:"
ls -lh work/base.img

# Step 3: Resize image to 120GB
echo ""
echo "==> Resizing image to 120GB..."
cd work
qemu-img resize base.img 120G

echo "Resized image:"
ls -lh base.img

# Step 4: Setup loop device and expand partition
echo ""
echo "==> Setting up loop device..."
RESIZE_LOOP=$(losetup -f --show base.img)
echo "Loop device: ${RESIZE_LOOP}"

echo ""
echo "==> Resizing partition 2 to use all space..."
parted ${RESIZE_LOOP} ---pretend-input-tty <<EOF
resizepart
2
100%
Yes
EOF

echo "Updating partition table..."
partprobe ${RESIZE_LOOP}
sleep 2

# Step 5: Expand filesystem using kpartx
echo ""
echo "==> Expanding filesystem to 120GB..."
kpartx -av ${RESIZE_LOOP}
sleep 2

# Get partition device name
RESIZE_LOOP_NAME=$(basename ${RESIZE_LOOP})
RESIZE_PART="/dev/mapper/${RESIZE_LOOP_NAME}p2"

if [ ! -b "${RESIZE_PART}" ]; then
    echo "ERROR: Partition device ${RESIZE_PART} not found"
    ls -la /dev/mapper/
    kpartx -dv ${RESIZE_LOOP}
    losetup -d ${RESIZE_LOOP}
    exit 1
fi

echo "Root partition: ${RESIZE_PART}"

# Run e2fsck (Debian Trixie e2fsprogs supports FEATURE_C12)
echo "Running e2fsck..."
e2fsck -f -y ${RESIZE_PART} || {
    echo "WARNING: e2fsck reported errors, but continuing..."
}

# Resize filesystem to full 120GB
echo "Running resize2fs to expand filesystem..."
resize2fs ${RESIZE_PART}

# Cleanup resize operations
echo "Cleaning up resize operations..."
kpartx -dv ${RESIZE_LOOP}
losetup -d ${RESIZE_LOOP}
sync
sleep 3

# Verify cleanup completed with retry loop
echo "Verifying loop device cleanup..."
CLEANUP_RETRY=0
CLEANUP_MAX_RETRIES=5
RESIZE_LOOP_NAME=$(basename ${RESIZE_LOOP})

while [ $CLEANUP_RETRY -lt $CLEANUP_MAX_RETRIES ]; do
    if losetup -a | grep -q "${RESIZE_LOOP_NAME}"; then
        CLEANUP_RETRY=$((CLEANUP_RETRY + 1))
        echo "WARNING: Loop device ${RESIZE_LOOP_NAME} still in use (attempt $CLEANUP_RETRY/$CLEANUP_MAX_RETRIES)"

        if [ $CLEANUP_RETRY -lt $CLEANUP_MAX_RETRIES ]; then
            echo "Forcing detach..."
            losetup -d ${RESIZE_LOOP} 2>/dev/null || true
            sync
            CLEANUP_SLEEP=$((2 * CLEANUP_RETRY))
            echo "Waiting ${CLEANUP_SLEEP} seconds..."
            sleep $CLEANUP_SLEEP
        else
            echo "ERROR: Failed to detach loop device after $CLEANUP_MAX_RETRIES attempts"
            echo "Active loop devices:"
            losetup -a
            exit 1
        fi
    else
        echo "✅ Loop device ${RESIZE_LOOP_NAME} successfully detached"
        break
    fi
done

echo "✅ Filesystem resized to 120GB"
cd /workspace

# Verify base.img exists and is accessible
if [ ! -f "work/base.img" ]; then
    echo "ERROR: work/base.img not found after resize!"
    ls -lha work/
    exit 1
fi

# Step 6: Setup loop device for build operations
echo ""
echo "==> Setting up loop device for build..."

# Retry loop device creation with exponential backoff
RETRY_COUNT=0
MAX_RETRIES=5
LOOP_DEVICE=""

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    LOOP_DEVICE=$(losetup -f --show work/base.img 2>&1) && break

    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "WARNING: Failed to create loop device (attempt $RETRY_COUNT/$MAX_RETRIES)"
    echo "Error: $LOOP_DEVICE"

    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
        SLEEP_TIME=$((2 ** RETRY_COUNT))
        echo "Retrying in ${SLEEP_TIME} seconds..."
        sleep $SLEEP_TIME

        # Clean up any stale loop devices
        echo "Cleaning up stale loop devices..."
        losetup -D 2>/dev/null || true
        sync
    fi
done

if [ -z "$LOOP_DEVICE" ] || [ ! -b "$LOOP_DEVICE" ]; then
    echo "ERROR: Failed to create loop device after $MAX_RETRIES attempts"
    echo "Checking loop devices:"
    losetup -a
    echo "Checking base.img:"
    ls -lh work/base.img
    echo "Checking /dev/loop*:"
    ls -l /dev/loop* | head -20
    exit 1
fi
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

cd /workspace

# Step 7: Mount partitions
echo ""
echo "==> Mounting partitions..."
mkdir -p /tmp/boot /tmp/root
mount ${ROOT_DEV} /tmp/root
mount ${BOOT_DEV} /tmp/boot

# Step 8: Install Kubernetes
echo ""
echo "==> Installing Kubernetes ${K8S_VERSION}..."
./image-build/scripts/01-install-k8s.sh /tmp/root "${K8S_VERSION}"

# Step 9: Install and configure cloud-init
echo ""
echo "==> Installing and configuring cloud-init..."
./image-build/scripts/02-install-cloudinit.sh /tmp/root

# Step 10: Cleanup and optimize
echo ""
echo "==> Cleaning up and optimizing..."
./image-build/scripts/04-cleanup.sh /tmp/root

# Step 11: Unmount and finalize
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

# Step 12: Shrink image (DISABLED for testing - image will be larger)
echo ""
echo "==> Skipping image shrinking (using unshrunk image for testing)..."

cd /workspace

# Step 13: Create output artifacts
echo ""
echo "==> Creating output artifacts..."
mkdir -p output

# Critical: Final sync before copying to ensure base.img is fully written
echo "Syncing filesystem before copy..."
sync
sleep 2

# Copy disk image
echo "Copying image file..."
cp work/base.img output/rpi5-k8s-${IMAGE_VERSION}.img

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
