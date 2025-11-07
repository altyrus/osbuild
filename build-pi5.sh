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

# Parse arguments
OUTPUT_DIR="${1:-$(pwd)/output}"
K8S_VERSION="${2:-1.28.0}"
IMAGE_VERSION="${3:-docker-$(date +%Y%m%d-%H%M%S)}"
CACHE_DIR="${CACHE_DIR:-$(pwd)/image-build/cache}"

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
echo "Starting build (15-30 minutes)..."
echo ""

# Run build with volume mounts
docker run --rm --privileged \
    -v "${OUTPUT_DIR}:/workspace/output" \
    -v "${CACHE_DIR}:/workspace/image-build/cache" \
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
