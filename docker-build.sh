#!/bin/bash
#
# docker-build.sh - Simple Docker-based build wrapper
#
# Usage:
#   ./docker-build.sh [output_dir] [k8s_version]
#
# Examples:
#   ./docker-build.sh                          # Defaults: ./output, K8s 1.28.0
#   ./docker-build.sh /path/to/output          # Custom output dir
#   ./docker-build.sh ./output 1.29.0          # Custom K8s version
#

set -euo pipefail

# Parse arguments
OUTPUT_DIR="${1:-$(pwd)/output}"
K8S_VERSION="${2:-1.28.0}"
IMAGE_VERSION="${3:-docker-$(date +%Y%m%d-%H%M%S)}"

# Ensure output directory exists
mkdir -p "${OUTPUT_DIR}"

# Get absolute path
OUTPUT_DIR=$(cd "${OUTPUT_DIR}" && pwd)

echo "=========================================="
echo "OSBuild - Docker Build"
echo "=========================================="
echo "Output directory: ${OUTPUT_DIR}"
echo "Kubernetes version: ${K8S_VERSION}"
echo "Image version: ${IMAGE_VERSION}"
echo "=========================================="
echo ""

# Check if Docker is running
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker is not running"
    echo "Please start Docker and try again"
    exit 1
fi

# Build and run using docker-compose
export OUTPUT_DIR
export K8S_VERSION
export IMAGE_VERSION

echo "Building Docker image..."
docker-compose build

echo ""
echo "Starting build..."
echo "(This will take 15-30 minutes depending on your hardware)"
echo ""

docker-compose up --abort-on-container-exit

# Check if build succeeded
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo ""
    echo "=========================================="
    echo "✅ Build completed successfully!"
    echo "=========================================="
    echo ""
    echo "Output files in: ${OUTPUT_DIR}"
    echo ""
    ls -lh "${OUTPUT_DIR}/"*.img 2>/dev/null || true
    ls -lh "${OUTPUT_DIR}"/netboot/*.tar.gz 2>/dev/null || true
    echo ""
    echo "To flash to NVMe:"
    echo "  sudo dd if=${OUTPUT_DIR}/rpi5-k8s-*.img of=/dev/nvme0n1 bs=4M status=progress conv=fsync"
    echo ""
else
    echo ""
    echo "=========================================="
    echo "❌ Build failed with exit code: $EXIT_CODE"
    echo "=========================================="
    echo ""
    echo "Check logs above for details"
    echo ""
    exit $EXIT_CODE
fi

# Cleanup
docker-compose down 2>/dev/null || true
