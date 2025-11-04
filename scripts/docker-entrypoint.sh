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

# Step 1: Download base image if not cached
if [[ ! -f "image-build/cache/${RASPIOS_VERSION}.img.xz" ]]; then
    echo ""
    echo "==> Downloading Raspberry Pi OS base image..."
    mkdir -p image-build/cache
    cd image-build/cache
    wget -q --show-progress \
        "https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-07-04/${RASPIOS_VERSION}.img.xz"
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
truncate -s +2G base.img
echo ", +" | sfdisk -N 2 base.img

# Setup loop device
LOOP_DEVICE=$(losetup -fP --show base.img)
echo "Loop device: ${LOOP_DEVICE}"

# Cleanup function
cleanup() {
    echo ""
    echo "==> Cleaning up..."
    umount /tmp/boot 2>/dev/null || true
    umount /tmp/root 2>/dev/null || true
    losetup -d ${LOOP_DEVICE} 2>/dev/null || true
}
trap cleanup EXIT

# Resize filesystem
e2fsck -f ${LOOP_DEVICE}p2 || true
resize2fs ${LOOP_DEVICE}p2

cd /workspace

# Step 4: Mount partitions
echo ""
echo "==> Mounting partitions..."
mkdir -p /tmp/boot /tmp/root
mount ${LOOP_DEVICE}p2 /tmp/root
mount ${LOOP_DEVICE}p1 /tmp/boot

# Step 5: Install Kubernetes
echo ""
echo "==> Installing Kubernetes ${K8S_VERSION}..."
./image-build/scripts/01-install-k8s.sh /tmp/root "${K8S_VERSION}"

# Step 6: Install bootstrap framework
echo ""
echo "==> Installing bootstrap framework..."
./image-build/scripts/02-install-bootstrap.sh /tmp/root

# Step 7: Configure first-boot
echo ""
echo "==> Configuring first-boot service..."
export GITHUB_SHA="${IMAGE_VERSION}"
./image-build/scripts/03-configure-firstboot.sh /tmp/root

# Step 8: Cleanup and optimize
echo ""
echo "==> Cleaning up and optimizing..."
./image-build/scripts/04-cleanup.sh /tmp/root

# Step 9: Unmount and finalize
echo ""
echo "==> Unmounting partitions..."
umount /tmp/boot
umount /tmp/root
losetup -d ${LOOP_DEVICE}
trap - EXIT  # Remove trap

# Step 10: Shrink image
echo ""
echo "==> Shrinking image..."
cd image-build/work
../../scripts/shrink-image.sh base.img

cd /workspace

# Step 11: Create output artifacts
echo ""
echo "==> Creating output artifacts..."
mkdir -p output/netboot

# Copy disk image
cp image-build/work/base.img output/rpi5-k8s-${IMAGE_VERSION}.img

# Extract rootfs for netboot
./scripts/extract-rootfs.sh \
    output/rpi5-k8s-${IMAGE_VERSION}.img \
    output/netboot/rootfs.tar.gz

# Generate checksums
cd output
sha256sum rpi5-k8s-${IMAGE_VERSION}.img > rpi5-k8s-${IMAGE_VERSION}.img.sha256
sha256sum netboot/rootfs.tar.gz > netboot/rootfs.tar.gz.sha256

# Create metadata
cat > metadata.json <<EOF
{
  "version": "${IMAGE_VERSION}",
  "kubernetes_version": "${K8S_VERSION}",
  "base_image": "${RASPIOS_VERSION}",
  "build_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "build_type": "docker",
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
echo "Output files:"
ls -lh output/
echo ""
echo "Netboot files:"
ls -lh output/netboot/
echo ""
echo "Files are available in your OUTPUT_DIR on the host"
echo "=========================================="
