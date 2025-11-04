#!/bin/bash
#
# extract-rootfs.sh - Extract rootfs from disk image for netboot
#
# This script extracts the root filesystem from a disk image
# and creates a tarball suitable for NFS netboot deployment.
#
# Usage: ./extract-rootfs.sh <disk.img> <output.tar.gz>
#

set -euo pipefail

DISK_IMAGE="${1:?Disk image path required}"
OUTPUT_TAR="${2:?Output tarball path required}"

if [[ ! -f "$DISK_IMAGE" ]]; then
    echo "ERROR: Disk image not found: $DISK_IMAGE"
    exit 1
fi

echo "=========================================="
echo "Extracting rootfs from disk image"
echo "Input: $DISK_IMAGE"
echo "Output: $OUTPUT_TAR"
echo "=========================================="

# Create temporary mount point
MOUNT_DIR=$(mktemp -d)

cleanup() {
    echo "Cleaning up..."
    if mountpoint -q "$MOUNT_DIR"; then
        umount "$MOUNT_DIR" || true
    fi
    kpartx -dv "$LOOP_DEVICE" 2>/dev/null || true
    losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    rm -rf "$MOUNT_DIR"
}

trap cleanup EXIT

echo "Setting up loop device..."
LOOP_DEVICE=$(losetup -f --show "$DISK_IMAGE")
echo "Loop device: $LOOP_DEVICE"

# Use kpartx for Docker compatibility
kpartx -av "$LOOP_DEVICE"
sleep 1

# Get partition device names
LOOP_NAME=$(basename "$LOOP_DEVICE")
ROOT_DEV="/dev/mapper/${LOOP_NAME}p2"

echo "Mounting root partition..."
mount "${ROOT_DEV}" "$MOUNT_DIR"

echo "Creating tarball..."
OUTPUT_DIR=$(dirname "$OUTPUT_TAR")
mkdir -p "$OUTPUT_DIR"

# Create tarball preserving permissions and attributes
tar -czf "$OUTPUT_TAR" \
    --numeric-owner \
    --preserve-permissions \
    --xattrs \
    -C "$MOUNT_DIR" \
    .

echo "Calculating checksum..."
sha256sum "$OUTPUT_TAR" > "${OUTPUT_TAR}.sha256"

echo "=========================================="
echo "Rootfs extraction completed"
echo "Size: $(du -h "$OUTPUT_TAR" | cut -f1)"
echo "Checksum: $(cat "${OUTPUT_TAR}.sha256")"
echo "=========================================="
