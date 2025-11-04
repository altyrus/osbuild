#!/bin/bash
#
# docker-verify.sh - Run image verification in Docker
#
# This script runs the verification inside a privileged Docker container.
#
# Usage: ./docker-verify.sh <path-to-image>
#

set -euo pipefail

IMAGE_PATH="${1:?Image path required}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

if [[ ! -f "$IMAGE_PATH" ]]; then
    echo "ERROR: Image not found: $IMAGE_PATH"
    exit 1
fi

# Convert to absolute path
IMAGE_PATH=$(readlink -f "$IMAGE_PATH")
IMAGE_DIR=$(dirname "$IMAGE_PATH")
IMAGE_NAME=$(basename "$IMAGE_PATH")

echo "=========================================="
echo "Docker Image Verification"
echo "=========================================="
echo "Image: $IMAGE_NAME"
echo "=========================================="

# Run verification in Docker
docker run --rm --privileged \
    -v "${IMAGE_DIR}:/images:ro" \
    -v "${SCRIPT_DIR}:/scripts:ro" \
    ubuntu:22.04 \
    bash -c "
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq kpartx util-linux mount e2fsprogs > /dev/null 2>&1
        bash /scripts/verify-image.sh /images/${IMAGE_NAME}
    "
