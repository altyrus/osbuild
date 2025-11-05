#!/bin/bash
#
# verify-cloudinit.sh - Verify cloud-init configuration in built image
#
# This script mounts the image and checks that cloud-init is properly configured.
#
# Usage: ./verify-cloudinit.sh <path-to-image>
#

set -euo pipefail

IMAGE_PATH="${1:?Image path required}"

echo "=========================================="
echo "OSBuild - Cloud-init Verification"
echo "=========================================="
echo "Image: ${IMAGE_PATH}"
echo "=========================================="
echo ""

# Verify image exists
if [[ ! -f "${IMAGE_PATH}" ]]; then
    echo "❌ ERROR: Image not found: ${IMAGE_PATH}"
    exit 1
fi

# Setup loop device
LOOP_DEVICE=$(sudo losetup -f --show "${IMAGE_PATH}")
echo "Loop device: ${LOOP_DEVICE}"

# Use kpartx to create partition mappings
sudo kpartx -av ${LOOP_DEVICE}
sleep 1

# Get partition device names
LOOP_NAME=$(basename ${LOOP_DEVICE})
BOOT_DEV="/dev/mapper/${LOOP_NAME}p1"
ROOT_DEV="/dev/mapper/${LOOP_NAME}p2"

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    sudo umount /tmp/verify-boot 2>/dev/null || true
    sudo umount /tmp/verify-root 2>/dev/null || true
    sudo kpartx -dv ${LOOP_DEVICE} 2>/dev/null || true
    sudo losetup -d ${LOOP_DEVICE} 2>/dev/null || true
    sudo rmdir /tmp/verify-boot 2>/dev/null || true
    sudo rmdir /tmp/verify-root 2>/dev/null || true
}
trap cleanup EXIT

# Mount partitions
sudo mkdir -p /tmp/verify-boot /tmp/verify-root
sudo mount ${ROOT_DEV} /tmp/verify-root
sudo mount ${BOOT_DEV} /tmp/verify-boot

echo ""
echo "Verification Results:"
echo "=========================================="

FAILED=0

# Check 1: Cloud-init package installed
echo -n "1. Cloud-init package installed... "
if sudo chroot /tmp/verify-root dpkg -l | grep -q "^ii.*cloud-init"; then
    VERSION=$(sudo chroot /tmp/verify-root dpkg -l cloud-init | grep "^ii" | awk '{print $3}')
    echo "✅ YES (${VERSION})"
else
    echo "❌ NO"
    FAILED=1
fi

# Check 2: user-data exists in boot partition
echo -n "2. user-data in boot partition... "
if [[ -f "/tmp/verify-boot/user-data" ]]; then
    SIZE=$(stat -c%s "/tmp/verify-boot/user-data")
    echo "✅ YES (${SIZE} bytes)"
else
    echo "❌ NO"
    FAILED=1
fi

# Check 3: meta-data exists in boot partition
echo -n "3. meta-data in boot partition... "
if [[ -f "/tmp/verify-boot/meta-data" ]]; then
    echo "✅ YES"
else
    echo "❌ NO"
    FAILED=1
fi

# Check 4: Cloud-init services enabled
echo -n "4. Cloud-init services enabled... "
SERVICES_OK=0
for service in cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service; do
    if sudo test -L "/tmp/verify-root/etc/systemd/system/cloud-init.target.wants/${service}"; then
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

# Check 5: NoCloud datasource configured
echo -n "5. NoCloud datasource configured... "
if sudo test -f "/tmp/verify-root/etc/cloud/cloud.cfg.d/99_nocloud.cfg"; then
    if sudo grep -q "NoCloud" "/tmp/verify-root/etc/cloud/cloud.cfg.d/99_nocloud.cfg"; then
        echo "✅ YES"
    else
        echo "❌ NO (file exists but NoCloud not configured)"
        FAILED=1
    fi
else
    echo "❌ NO (config file missing)"
    FAILED=1
fi

# Check 6: Cloud-init state cleaned
echo -n "6. Cloud-init state cleaned... "
if sudo test -d "/tmp/verify-root/var/lib/cloud"; then
    INSTANCE_FILES=$(sudo find /tmp/verify-root/var/lib/cloud/instances -type f 2>/dev/null | wc -l)
    if [[ ${INSTANCE_FILES} -eq 0 ]]; then
        echo "✅ YES (ready for first boot)"
    else
        echo "⚠️  PARTIAL (${INSTANCE_FILES} instance files remain)"
    fi
else
    echo "✅ YES (cloud dir created)"
fi

# Check 7: Verify user-data content
echo -n "7. user-data contains cloud-config... "
if sudo grep -q "^#cloud-config" "/tmp/verify-boot/user-data"; then
    echo "✅ YES"
else
    echo "❌ NO"
    FAILED=1
fi

# Check 8: Old bootstrap NOT present
echo -n "8. Old bootstrap framework removed... "
if sudo test -f "/tmp/verify-root/etc/systemd/system/first-boot.service"; then
    echo "⚠️  WARNING (old first-boot service still exists)"
else
    echo "✅ YES"
fi

echo "=========================================="
echo ""

if [[ ${FAILED} -eq 0 ]]; then
    echo "✅ Cloud-init verification PASSED"
    echo ""
    echo "The image is ready to boot and should:"
    echo "  • Run cloud-init automatically on first boot"
    echo "  • Create user 'pi' with password 'raspberry'"
    echo "  • Configure SSH and network"
    echo "  • NOT prompt for username or password"
    echo ""
    exit 0
else
    echo "❌ Cloud-init verification FAILED"
    echo ""
    echo "Review the failures above and rebuild the image."
    echo ""
    exit 1
fi
