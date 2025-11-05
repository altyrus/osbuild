#!/bin/bash
#
# docker-verify-cloudinit.sh - Verify cloud-init in Docker (no host deps)
#
# This mounts and verifies cloud-init configuration using only Docker
#

set -euo pipefail

IMAGE_PATH="${1:?Image path required}"

if [[ ! -f "${IMAGE_PATH}" ]]; then
    echo "ERROR: Image not found: ${IMAGE_PATH}"
    exit 1
fi

IMAGE_PATH=$(realpath "${IMAGE_PATH}")
IMAGE_NAME=$(basename "${IMAGE_PATH}")

echo "=========================================="
echo "Cloud-init Verification (Docker)"
echo "=========================================="
echo "Image: ${IMAGE_NAME}"
echo "=========================================="
echo ""

# Run verification in Docker with privileged access
docker run --rm --privileged \
    -v "${IMAGE_PATH}:/test.img:ro" \
    ubuntu:22.04 \
    bash -c '
set -e

# Install required tools
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq 2>&1 | grep -v "^Get:" || true
apt-get install -y -qq kpartx parted mount 2>&1 | grep -v "^Selecting\|^Preparing\|^Unpacking" || true

echo "Setting up loop device..."
LOOP_DEVICE=$(losetup -f --show /test.img)
echo "Loop device: ${LOOP_DEVICE}"

# Create partition mappings
kpartx -av ${LOOP_DEVICE}
sleep 2

# Get partition names
LOOP_NAME=$(basename ${LOOP_DEVICE})
BOOT_DEV="/dev/mapper/${LOOP_NAME}p1"
ROOT_DEV="/dev/mapper/${LOOP_NAME}p2"

# Cleanup function
cleanup() {
    umount /mnt/boot 2>/dev/null || true
    umount /mnt/root 2>/dev/null || true
    kpartx -dv ${LOOP_DEVICE} 2>/dev/null || true
    losetup -d ${LOOP_DEVICE} 2>/dev/null || true
}
trap cleanup EXIT

# Mount partitions
mkdir -p /mnt/boot /mnt/root
mount ${ROOT_DEV} /mnt/root
mount ${BOOT_DEV} /mnt/boot

echo ""
echo "Verification Results:"
echo "=========================================="

FAILED=0

# Check 1: Cloud-init package installed
echo -n "1. Cloud-init package... "
if chroot /mnt/root dpkg -l 2>/dev/null | grep -q "^ii.*cloud-init"; then
    VERSION=$(chroot /mnt/root dpkg -l cloud-init 2>/dev/null | grep "^ii" | awk "{print \$3}")
    echo "✅ YES (${VERSION})"
else
    echo "❌ NO"
    FAILED=1
fi

# Check 2: user-data in boot partition
echo -n "2. user-data in boot... "
if [[ -f "/mnt/boot/user-data" ]]; then
    SIZE=$(stat -c%s "/mnt/boot/user-data")
    echo "✅ YES (${SIZE} bytes)"
else
    echo "❌ NO"
    FAILED=1
fi

# Check 3: meta-data in boot partition
echo -n "3. meta-data in boot... "
if [[ -f "/mnt/boot/meta-data" ]]; then
    echo "✅ YES"
else
    echo "❌ NO"
    FAILED=1
fi

# Check 4: NoCloud datasource configured
echo -n "4. NoCloud datasource... "
if [[ -f "/mnt/root/etc/cloud/cloud.cfg.d/99_nocloud.cfg" ]]; then
    if grep -q "NoCloud" "/mnt/root/etc/cloud/cloud.cfg.d/99_nocloud.cfg"; then
        echo "✅ YES"
    else
        echo "❌ NO (file exists but NoCloud not configured)"
        FAILED=1
    fi
else
    echo "❌ NO (config file missing)"
    FAILED=1
fi

# Check 5: Cloud-init services enabled
echo -n "5. Cloud-init services... "
SERVICES_OK=0
for service in cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service; do
    if test -L "/mnt/root/etc/systemd/system/cloud-init.target.wants/${service}"; then
        ((SERVICES_OK++))
    fi
done
if [[ ${SERVICES_OK} -eq 4 ]]; then
    echo "✅ YES (all 4 services)"
else
    echo "⚠️  PARTIAL (${SERVICES_OK}/4 services)"
    if [[ ${SERVICES_OK} -eq 0 ]]; then
        FAILED=1
    fi
fi

# Check 6: Verify user-data content
echo -n "6. user-data format... "
if grep -q "^#cloud-config" "/mnt/boot/user-data"; then
    echo "✅ YES"
else
    echo "❌ NO"
    FAILED=1
fi

# Check 7: Show user-data preview
echo ""
echo "user-data preview:"
echo "---"
head -20 /mnt/boot/user-data
echo "---"

echo ""
echo "=========================================="

if [[ ${FAILED} -eq 0 ]]; then
    echo "✅ Cloud-init verification PASSED"
    echo ""
    echo "The image is properly configured for cloud-init."
    echo ""
    exit 0
else
    echo "❌ Cloud-init verification FAILED"
    echo ""
    exit 1
fi
'

echo ""
echo "Verification complete."
