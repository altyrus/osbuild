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

# Register QEMU ARM64 binfmt handler on host (needed for chroot in Docker)
echo "Registering QEMU ARM64 binfmt handler..."
if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    docker run --rm --privileged multiarch/qemu-user-static --reset -p yes >/dev/null 2>&1 || {
        echo "WARNING: Could not register QEMU handlers, ARM64 emulation may not work"
    }
    echo "QEMU ARM64 handler registered"
else
    echo "QEMU ARM64 handler already registered"
fi

# Build image
echo "Building Docker image..."
docker build -t osbuild:latest "${PROJECT_DIR}"

echo ""
echo "Downloading base image (all processing done in Docker)..."
echo ""

# Download base image if needed (Docker will handle extraction and resize)
WORK_DIR="${PROJECT_DIR}/work/pi5"
mkdir -p "${WORK_DIR}"

RASPIOS_VERSION="2025-10-01-raspios-trixie-arm64-lite"
BASE_IMAGE_XZ="${CACHE_DIR}/${RASPIOS_VERSION}.img.xz"

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

echo ""
echo "Base image ready. Starting Docker build..."
echo "Docker will handle extraction, resize, and filesystem expansion."
echo ""

# Run build with volume mounts
docker run --rm --privileged \
    -v "${OUTPUT_DIR}:/workspace/output" \
    -v "${CACHE_DIR}:/workspace/cache" \
    -v "${WORK_DIR}:/workspace/work" \
    -e K8S_VERSION="${K8S_VERSION}" \
    -e IMAGE_VERSION="${IMAGE_VERSION}" \
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
