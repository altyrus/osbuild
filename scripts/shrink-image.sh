#!/bin/bash
#
# shrink-image.sh - Shrink disk image to minimum size
#
# This script shrinks a disk image by resizing the filesystem
# and truncating unused space.
#
# Usage: sudo ./shrink-image.sh <disk.img>
#

set -euo pipefail

DISK_IMAGE="${1:?Disk image path required}"

if [[ ! -f "$DISK_IMAGE" ]]; then
    echo "ERROR: Disk image not found: $DISK_IMAGE"
    exit 1
fi

echo "=========================================="
echo "Shrinking disk image"
echo "Image: $DISK_IMAGE"
echo "Original size: $(du -h "$DISK_IMAGE" | cut -f1)"
echo "=========================================="

# Setup loop device
echo "Setting up loop device..."
LOOP_DEVICE=$(losetup -fP --show "$DISK_IMAGE")
echo "Loop device: $LOOP_DEVICE"

cleanup() {
    echo "Cleaning up..."
    losetup -d "$LOOP_DEVICE" 2>/dev/null || true
}

trap cleanup EXIT

# Wait for partition devices
sleep 1

echo "Checking filesystem..."
e2fsck -f -y "${LOOP_DEVICE}p2" || true

echo "Getting filesystem info..."
BLOCK_SIZE=$(tune2fs -l "${LOOP_DEVICE}p2" | grep "Block size" | awk '{print $3}')
BLOCK_COUNT=$(tune2fs -l "${LOOP_DEVICE}p2" | grep "Block count" | awk '{print $3}')

echo "Block size: $BLOCK_SIZE"
echo "Block count: $BLOCK_COUNT"

echo "Shrinking filesystem to minimum size..."
resize2fs -M "${LOOP_DEVICE}p2"

echo "Getting new filesystem size..."
NEW_BLOCK_COUNT=$(tune2fs -l "${LOOP_DEVICE}p2" | grep "Block count" | awk '{print $3}')
echo "New block count: $NEW_BLOCK_COUNT"

# Calculate new partition size (add 10% buffer)
NEW_SIZE_BYTES=$((NEW_BLOCK_COUNT * BLOCK_SIZE))
BUFFER_SIZE=$((NEW_SIZE_BYTES / 10))
TOTAL_SIZE=$((NEW_SIZE_BYTES + BUFFER_SIZE))
NEW_SIZE_MB=$((TOTAL_SIZE / 1024 / 1024))

echo "New filesystem size: ${NEW_SIZE_MB}MB"

# Get partition start
PART_START=$(parted "$DISK_IMAGE" unit s print | grep "^ 2" | awk '{print $2}' | sed 's/s//')
echo "Partition start: ${PART_START}s"

# Calculate new end sector
SECTOR_SIZE=512
NEW_SIZE_SECTORS=$((TOTAL_SIZE / SECTOR_SIZE))
NEW_END_SECTOR=$((PART_START + NEW_SIZE_SECTORS))

echo "Resizing partition..."
parted "$DISK_IMAGE" ---pretend-input-tty <<EOF
resizepart
2
${NEW_END_SECTOR}s
quit
EOF

# Cleanup loop device before truncating
losetup -d "$LOOP_DEVICE"
trap - EXIT

# Truncate image
BOOT_SIZE=$((PART_START * SECTOR_SIZE))
NEW_IMAGE_SIZE=$((BOOT_SIZE + TOTAL_SIZE))
NEW_IMAGE_SIZE_MB=$((NEW_IMAGE_SIZE / 1024 / 1024))

echo "Truncating image to ${NEW_IMAGE_SIZE_MB}MB..."
truncate -s "$NEW_IMAGE_SIZE" "$DISK_IMAGE"

echo "=========================================="
echo "Image shrinking completed"
echo "Final size: $(du -h "$DISK_IMAGE" | cut -f1)"
echo "=========================================="
