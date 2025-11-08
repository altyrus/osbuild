#!/bin/bash
#
# build-local.sh - Local build script for testing
#
# This script allows you to build the image locally for testing
# without using GitHub Actions. Useful for development and debugging.
#
# Requirements:
# - Linux system with ARM64 emulation support
# - sudo access
# - qemu-user-static, kpartx, parted, etc.
#
# Usage: ./build-local.sh [k8s_version]
#

set -euo pipefail

K8S_VERSION="${1:-1.28.0}"
IMAGE_VERSION="local-$(date +%Y%m%d-%H%M%S)"
RASPIOS_VERSION="2024-07-04-raspios-bookworm-arm64-lite"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "OSBuild - Local Build Script"
echo "=========================================="
echo "Kubernetes version: $K8S_VERSION"
echo "Image version: $IMAGE_VERSION"
echo "Project root: $PROJECT_ROOT"
echo "=========================================="

# Check for required tools
check_dependencies() {
    local missing=()

    for tool in qemu-aarch64-static kpartx parted wget curl tar xz; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required tools: ${missing[*]}"
        echo ""
        echo "Install with:"
        echo "  sudo apt-get install qemu-user-static qemu-utils kpartx parted wget curl xz-utils"
        exit 1
    fi
}

echo "Checking dependencies..."
check_dependencies

# Create directories
mkdir -p "$PROJECT_ROOT/cache/pi5"
mkdir -p "$PROJECT_ROOT/work/pi5"
mkdir -p "$PROJECT_ROOT/output/pi5"

cd "$PROJECT_ROOT"

# Download base image if not cached
if [[ ! -f "cache/pi5/${RASPIOS_VERSION}.img.xz" ]]; then
    echo "Downloading Raspberry Pi OS base image..."
    wget -P cache/pi5 \
        "https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-07-04/${RASPIOS_VERSION}.img.xz"
else
    echo "Using cached base image"
fi

# Extract base image
echo "Extracting base image..."
xz -dc "cache/pi5/${RASPIOS_VERSION}.img.xz" > "work/pi5/base.img"

# Expand image
echo "Expanding image for customization..."
truncate -s +2G "work/pi5/base.img"

# Expand partition
echo "Expanding partition..."
echo ", +" | sudo sfdisk -N 2 "work/pi5/base.img"

# Setup loop device
echo "Setting up loop device..."
LOOP_DEVICE=$(sudo losetup -fP --show "work/pi5/base.img")
echo "Loop device: $LOOP_DEVICE"

cleanup() {
    echo "Cleaning up..."
    sudo umount /tmp/boot 2>/dev/null || true
    sudo umount /tmp/root 2>/dev/null || true
    sudo losetup -d "$LOOP_DEVICE" 2>/dev/null || true
}

trap cleanup EXIT

# Resize filesystem
echo "Resizing filesystem..."
sudo e2fsck -f "${LOOP_DEVICE}p2" || true
sudo resize2fs "${LOOP_DEVICE}p2"

# Mount partitions
echo "Mounting partitions..."
sudo mkdir -p /tmp/boot /tmp/root
sudo mount "${LOOP_DEVICE}p2" /tmp/root
sudo mount "${LOOP_DEVICE}p1" /tmp/boot

# Run build scripts
echo ""
echo "=========================================="
echo "Running build scripts..."
echo "=========================================="

export K8S_VERSION
export GITHUB_SHA="$IMAGE_VERSION"

echo ""
echo "Step 1: Installing Kubernetes..."
sudo "$PROJECT_ROOT/image-build/scripts/01-install-k8s.sh" /tmp/root "$K8S_VERSION"

echo ""
echo "Step 2: Installing bootstrap framework..."
sudo "$PROJECT_ROOT/image-build/scripts/02-install-bootstrap.sh" /tmp/root

echo ""
echo "Step 3: Configuring first-boot..."
sudo "$PROJECT_ROOT/image-build/scripts/03-configure-firstboot.sh" /tmp/root

echo ""
echo "Step 4: Cleaning up..."
sudo "$PROJECT_ROOT/image-build/scripts/04-cleanup.sh" /tmp/root

# Unmount
echo ""
echo "Unmounting partitions..."
sudo umount /tmp/boot
sudo umount /tmp/root

# Shrink image
echo ""
echo "Shrinking image..."
sudo "$PROJECT_ROOT/scripts/shrink-image.sh" "work/pi5/base.img"

# Cleanup loop device
sudo losetup -d "$LOOP_DEVICE"
trap - EXIT

# Create output artifacts
echo ""
echo "Creating output artifacts..."
cp "work/pi5/base.img" "output/pi5/rpi5-k8s-${IMAGE_VERSION}.img"

# Extract rootfs
echo "Extracting rootfs..."
"$PROJECT_ROOT/scripts/extract-rootfs.sh" \
    "output/rpi5-k8s-${IMAGE_VERSION}.img" \
    "output/netboot/rootfs.tar.gz"

# Generate checksums
echo "Generating checksums..."
cd output
sha256sum "rpi5-k8s-${IMAGE_VERSION}.img" > "rpi5-k8s-${IMAGE_VERSION}.img.sha256"

# Create metadata
cat > metadata.json <<EOF
{
  "version": "${IMAGE_VERSION}",
  "kubernetes_version": "${K8S_VERSION}",
  "base_image": "${RASPIOS_VERSION}",
  "build_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "build_type": "local",
  "build_host": "$(hostname)"
}
EOF

cd ..

echo ""
echo "=========================================="
echo "Build completed successfully!"
echo "=========================================="
echo ""
echo "Output files:"
ls -lh output/
echo ""
ls -lh output/netboot/
echo ""
echo "Disk image: output/rpi5-k8s-${IMAGE_VERSION}.img"
echo "Rootfs: output/netboot/rootfs.tar.gz"
echo "Metadata: output/metadata.json"
echo ""
echo "To flash to NVMe:"
echo "  sudo dd if=output/rpi5-k8s-${IMAGE_VERSION}.img of=/dev/nvme0n1 bs=4M status=progress conv=fsync"
echo ""
echo "To deploy to netboot server:"
echo "  ./scripts/deploy-netboot.sh output/netboot/rootfs.tar.gz YOUR_SERVER"
echo "=========================================="
