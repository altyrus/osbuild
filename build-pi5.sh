#!/bin/bash
#
# build-pi5.sh - Raspberry Pi 5 Image Builder
#
# Pure Docker build (no docker-compose needed)
# Ultra-portable: Only requires Docker, nothing else
#
# Usage:
#   ./build-pi5.sh [output_dir] [k8s_version]
#

set -euo pipefail

# Lock file to prevent concurrent builds
LOCK_FILE="/tmp/osbuild-pi5.lock"

# Check for existing build
if [ -f "${LOCK_FILE}" ]; then
    LOCK_PID=$(cat "${LOCK_FILE}" 2>/dev/null || echo "")
    if [ -n "${LOCK_PID}" ] && kill -0 "${LOCK_PID}" 2>/dev/null; then
        echo "ERROR: Another Pi5 build is already running (PID: ${LOCK_PID})"
        echo "If this is incorrect, remove the lock file: ${LOCK_FILE}"
        exit 1
    else
        echo "Removing stale lock file..."
        rm -f "${LOCK_FILE}"
    fi
fi

# Create lock file
echo $$ > "${LOCK_FILE}"
trap "rm -f ${LOCK_FILE}" EXIT

# Parse arguments
OUTPUT_DIR="${1:-$(pwd)/output/pi5}"
K8S_VERSION="${2:-1.28.0}"
IMAGE_VERSION="${3:-docker-$(date +%Y%m%d-%H%M%S)}"
CACHE_DIR="${CACHE_DIR:-$(pwd)/cache/pi5}"

# Ensure directories exist
mkdir -p "${OUTPUT_DIR}"
mkdir -p "${CACHE_DIR}"

# Get absolute paths
OUTPUT_DIR=$(cd "${OUTPUT_DIR}" && pwd)
CACHE_DIR=$(cd "${CACHE_DIR}" && pwd)
PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

echo "=========================================="
echo "OSBuild - Raspberry Pi 5 Image Builder"
echo "=========================================="
echo "Project: ${PROJECT_DIR}"
echo "Output: ${OUTPUT_DIR}"
echo "Cache: ${CACHE_DIR}"
echo "Kubernetes: ${K8S_VERSION}"
echo "=========================================="
echo ""

# Check Docker
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker is not running"
    exit 1
fi

# Build image
echo "Building Docker image..."
docker build -t osbuild:latest "${PROJECT_DIR}"

echo ""
echo "Pre-processing base image (resize outside Docker)..."
echo ""

# Download and extract base image if needed
WORK_DIR="${PROJECT_DIR}/work/pi5"
mkdir -p "${WORK_DIR}"

RASPIOS_VERSION="2025-10-01-raspios-trixie-arm64-lite"
BASE_IMAGE_XZ="${CACHE_DIR}/${RASPIOS_VERSION}.img.xz"
BASE_IMAGE="${WORK_DIR}/base.img"

if [ ! -f "${BASE_IMAGE_XZ}" ]; then
    echo "Downloading base image..."
    if ! wget -q --show-progress \
        "https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-10-02/${RASPIOS_VERSION}.img.xz" \
        -O "${BASE_IMAGE_XZ}"; then
        echo "ERROR: Failed to download base image"
        rm -f "${BASE_IMAGE_XZ}"
        exit 1
    fi

    # Verify downloaded file is not empty
    if [ ! -s "${BASE_IMAGE_XZ}" ]; then
        echo "ERROR: Downloaded file is empty"
        rm -f "${BASE_IMAGE_XZ}"
        exit 1
    fi
    echo "Download complete: $(du -h ${BASE_IMAGE_XZ} | cut -f1)"
else
    echo "Using cached base image: ${BASE_IMAGE_XZ}"
fi

echo "Extracting base image..."
if ! xz -dc "${BASE_IMAGE_XZ}" > "${BASE_IMAGE}"; then
    echo "ERROR: Failed to extract base image"
    rm -f "${BASE_IMAGE}"
    exit 1
fi

# Verify extracted image
if [ ! -s "${BASE_IMAGE}" ]; then
    echo "ERROR: Extracted image is empty or missing"
    exit 1
fi

echo "Original image size:"
ls -lh "${BASE_IMAGE}"

echo ""
echo "Resizing image to 120GB..."
qemu-img resize "${BASE_IMAGE}" 120G

echo "Resized image:"
ls -lh "${BASE_IMAGE}"

echo ""
echo "Setting up loop device..."
LOOP_DEVICE=$(losetup -f --show "${BASE_IMAGE}")
echo "Loop device: ${LOOP_DEVICE}"

echo ""
echo "Resizing partition..."
# Get partition 2 info
PART_START=$(parted ${LOOP_DEVICE} unit s print | grep "^ 2" | awk '{print $2}' | sed 's/s//')
echo "Partition 2 starts at sector: ${PART_START}"

# Resize partition 2 to use all available space
parted ${LOOP_DEVICE} ---pretend-input-tty <<EOF
resizepart
2
100%
Yes
EOF

echo ""
echo "Updating kernel partition table..."
partprobe ${LOOP_DEVICE}
sleep 2

echo ""
echo "Checking and resizing filesystem..."
# Use kpartx to create device mappings
kpartx -av ${LOOP_DEVICE}
sleep 2

# Get partition device name (kpartx creates /dev/mapper/ devices)
LOOP_NAME=$(basename ${LOOP_DEVICE})
PART_DEVICE="/dev/mapper/${LOOP_NAME}p2"

if [ ! -b "${PART_DEVICE}" ]; then
    echo "ERROR: Partition device ${PART_DEVICE} not found"
    echo "Available devices:"
    ls -la /dev/mapper/
    kpartx -dv ${LOOP_DEVICE}
    losetup -d ${LOOP_DEVICE}
    exit 1
fi

echo "Partition device: ${PART_DEVICE}"

echo ""
echo "Running e2fsck..."
e2fsck -f -y ${PART_DEVICE} || {
    echo "WARNING: e2fsck reported errors, but continuing..."
}

echo ""
echo "Running resize2fs to full 120GB..."
resize2fs ${PART_DEVICE}

echo ""
echo "Filesystem resized. Cleaning up..."
kpartx -dv ${LOOP_DEVICE}
losetup -d ${LOOP_DEVICE}
echo "Cleanup complete."

echo ""
echo "Pre-processing complete. Starting Docker build..."
echo ""

# Run build with volume mounts
docker run --rm --privileged \
    -v "${OUTPUT_DIR}:/workspace/output" \
    -v "${CACHE_DIR}:/workspace/cache" \
    -v "${WORK_DIR}:/workspace/work" \
    -e K8S_VERSION="${K8S_VERSION}" \
    -e IMAGE_VERSION="${IMAGE_VERSION}" \
    -e SKIP_IMAGE_RESIZE=true \
    osbuild:latest

# Check result
if [ -f "${OUTPUT_DIR}/metadata.json" ]; then
    echo ""
    echo "=========================================="
    echo "✅ Build completed successfully!"
    echo "=========================================="
    echo ""
    echo "Output: ${OUTPUT_DIR}"
    ls -lh "${OUTPUT_DIR}/"*.img 2>/dev/null || true
    echo ""
    echo "Flash to NVMe:"
    echo "  sudo dd if=${OUTPUT_DIR}/rpi5-k8s-*.img of=/dev/nvme0n1 bs=4M status=progress conv=fsync"
    echo ""
else
    echo ""
    echo "❌ Build failed"
    exit 1
fi
