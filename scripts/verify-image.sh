#!/bin/bash
#
# verify-image.sh - Verify OS image contents
#
# This script mounts a disk image and verifies all components
# are installed and configured correctly.
#
# Usage: sudo ./verify-image.sh <disk.img>
#

set -euo pipefail

DISK_IMAGE="${1:?Disk image path required}"
ERRORS=0

if [[ ! -f "$DISK_IMAGE" ]]; then
    echo "ERROR: Disk image not found: $DISK_IMAGE"
    exit 1
fi

echo "=========================================="
echo "Verifying OS Image"
echo "Image: $DISK_IMAGE"
echo "=========================================="

# Create temporary mount points
BOOT_MOUNT=$(mktemp -d)
ROOT_MOUNT=$(mktemp -d)

cleanup() {
    echo ""
    echo "Cleaning up..."
    umount "$BOOT_MOUNT" 2>/dev/null || true
    umount "$ROOT_MOUNT" 2>/dev/null || true
    kpartx -dv "$LOOP_DEVICE" 2>/dev/null || true
    losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    rm -rf "$BOOT_MOUNT" "$ROOT_MOUNT"
}

trap cleanup EXIT

# Setup loop device
echo ""
echo "==> Mounting image..."
LOOP_DEVICE=$(losetup -f --show "$DISK_IMAGE")
echo "Loop device: $LOOP_DEVICE"

# Use kpartx for Docker compatibility
kpartx -av "$LOOP_DEVICE"
sleep 1

# Get partition device names
LOOP_NAME=$(basename "$LOOP_DEVICE")
BOOT_DEV="/dev/mapper/${LOOP_NAME}p1"
ROOT_DEV="/dev/mapper/${LOOP_NAME}p2"

# Mount partitions
mount "$ROOT_DEV" "$ROOT_MOUNT"
mount "$BOOT_DEV" "$BOOT_MOUNT"

echo "✓ Image mounted successfully"

# Test function
test_item() {
    local description="$1"
    local test_command="$2"

    if eval "$test_command"; then
        echo "✓ $description"
    else
        echo "✗ $description"
        ((ERRORS++))
    fi
}

echo ""
echo "==> Verifying boot configuration..."
test_item "Boot partition mounted" "mountpoint -q '$BOOT_MOUNT'"
test_item "cmdline.txt exists" "[[ -f '$BOOT_MOUNT/cmdline.txt' || -f '$BOOT_MOUNT/firmware/cmdline.txt' ]]"
test_item "config.txt exists" "[[ -f '$BOOT_MOUNT/config.txt' || -f '$BOOT_MOUNT/firmware/config.txt' ]]"

# Check cmdline for cgroup parameters
CMDLINE_FILE="$BOOT_MOUNT/cmdline.txt"
[[ ! -f "$CMDLINE_FILE" ]] && CMDLINE_FILE="$BOOT_MOUNT/firmware/cmdline.txt"
if [[ -f "$CMDLINE_FILE" ]]; then
    test_item "cmdline has cgroup_memory=1" "grep -q 'cgroup_memory=1' '$CMDLINE_FILE'"
    test_item "cmdline has cgroup_enable=memory" "grep -q 'cgroup_enable=memory' '$CMDLINE_FILE'"
fi

echo ""
echo "==> Verifying Kubernetes installation..."
test_item "containerd installed" "[[ -f '$ROOT_MOUNT/usr/bin/containerd' ]]"
test_item "kubeadm installed" "[[ -f '$ROOT_MOUNT/usr/bin/kubeadm' ]]"
test_item "kubelet installed" "[[ -f '$ROOT_MOUNT/usr/bin/kubelet' ]]"
test_item "kubectl installed" "[[ -f '$ROOT_MOUNT/usr/bin/kubectl' ]]"
test_item "crictl installed" "[[ -f '$ROOT_MOUNT/usr/local/bin/crictl' ]]"
test_item "CNI plugins installed" "[[ -d '$ROOT_MOUNT/opt/cni/bin' && -n \"\$(ls -A '$ROOT_MOUNT/opt/cni/bin')\" ]]"

echo ""
echo "==> Verifying systemd services..."
test_item "containerd service exists" "[[ -f '$ROOT_MOUNT/lib/systemd/system/containerd.service' ]]"
test_item "kubelet service exists" "[[ -f '$ROOT_MOUNT/lib/systemd/system/kubelet.service' ]]"
test_item "first-boot service exists" "[[ -f '$ROOT_MOUNT/etc/systemd/system/first-boot.service' ]]"
test_item "first-boot service enabled" "[[ -L '$ROOT_MOUNT/etc/systemd/system/multi-user.target.wants/first-boot.service' ]]"
test_item "SSH service enabled" "[[ -L '$ROOT_MOUNT/etc/systemd/system/multi-user.target.wants/ssh.service' ]]"

echo ""
echo "==> Verifying bootstrap framework..."
test_item "bootstrap.sh exists" "[[ -f '$ROOT_MOUNT/opt/bootstrap/bootstrap.sh' ]]"
test_item "bootstrap.sh is executable" "[[ -x '$ROOT_MOUNT/opt/bootstrap/bootstrap.sh' ]]"
test_item "bootstrap.conf exists" "[[ -f '$ROOT_MOUNT/etc/bootstrap.conf' ]]"
test_item "first-boot marker exists" "[[ -f '$ROOT_MOUNT/etc/first-boot-marker' ]]"

echo ""
echo "==> Verifying configuration files..."
test_item "containerd config exists" "[[ -f '$ROOT_MOUNT/etc/containerd/config.toml' ]]"
test_item "kubelet config dir exists" "[[ -d '$ROOT_MOUNT/etc/systemd/system/kubelet.service.d' ]]"
test_item "sysctl kubernetes config exists" "[[ -f '$ROOT_MOUNT/etc/sysctl.d/99-kubernetes.conf' ]]"
test_item "modules-load kubernetes config exists" "[[ -f '$ROOT_MOUNT/etc/modules-load.d/kubernetes.conf' ]]"

echo ""
echo "==> Verifying SSH configuration..."
test_item "SSH config exists" "[[ -f '$ROOT_MOUNT/etc/ssh/sshd_config' ]]"
test_item "PasswordAuthentication disabled" "grep -q 'PasswordAuthentication no' '$ROOT_MOUNT/etc/ssh/sshd_config'"
test_item "PubkeyAuthentication enabled" "grep -q 'PubkeyAuthentication yes' '$ROOT_MOUNT/etc/ssh/sshd_config'"

echo ""
echo "==> Verifying system configuration..."
test_item "hostname set" "[[ -f '$ROOT_MOUNT/etc/hostname' ]]"
test_item "hosts file configured" "[[ -f '$ROOT_MOUNT/etc/hosts' ]]"
test_item "os-image-version file exists" "[[ -f '$ROOT_MOUNT/etc/os-image-version' ]]"
test_item "swap disabled" "[[ -L '$ROOT_MOUNT/etc/systemd/system/swap.target' && \"\$(readlink '$ROOT_MOUNT/etc/systemd/system/swap.target')\" == '/dev/null' ]]"

echo ""
echo "==> Verifying package installations..."
test_item "git installed" "[[ -f '$ROOT_MOUNT/usr/bin/git' ]]"
test_item "curl installed" "[[ -f '$ROOT_MOUNT/usr/bin/curl' ]]"
test_item "jq installed" "[[ -f '$ROOT_MOUNT/usr/bin/jq' ]]"

echo ""
echo "=========================================="
if [[ $ERRORS -eq 0 ]]; then
    echo "✅ All verification checks passed!"
    echo "=========================================="
    exit 0
else
    echo "❌ $ERRORS verification check(s) failed!"
    echo "=========================================="
    exit 1
fi
