#!/bin/bash
#
# download-artifacts.sh - Download build artifacts from GitHub Actions
#
# This script downloads the latest build artifacts to local storage.
# Useful for testing images locally without waiting for releases.
#
# Usage: ./download-artifacts.sh [run-id]
#

set -euo pipefail

RUN_ID="${1:-}"
DOWNLOAD_DIR="${2:-./downloads}"

echo "=========================================="
echo "Download GitHub Actions Artifacts"
echo "=========================================="

# Check if gh is installed
if ! command -v gh &>/dev/null; then
    echo "ERROR: GitHub CLI (gh) is not installed"
    echo "Install: https://cli.github.com/"
    exit 1
fi

# Check if authenticated
if ! gh auth status &>/dev/null; then
    echo "ERROR: Not authenticated with GitHub"
    echo "Run: gh auth login"
    exit 1
fi

# Get repository info
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
echo "Repository: $REPO"

# If no run ID provided, get the latest successful run
if [[ -z "$RUN_ID" ]]; then
    echo "Finding latest successful build..."
    RUN_ID=$(gh run list \
        --workflow="Build Raspberry Pi OS Image" \
        --status=success \
        --limit 1 \
        --json databaseId \
        --jq '.[0].databaseId')

    if [[ -z "$RUN_ID" ]]; then
        echo "ERROR: No successful builds found"
        exit 1
    fi

    echo "Latest successful run ID: $RUN_ID"
fi

# Create download directory
mkdir -p "$DOWNLOAD_DIR"

echo ""
echo "Downloading artifacts..."
gh run download "$RUN_ID" --dir "$DOWNLOAD_DIR"

echo ""
echo "=========================================="
echo "Download completed!"
echo "=========================================="
echo ""
echo "Location: $DOWNLOAD_DIR"
echo ""

# List downloaded files
find "$DOWNLOAD_DIR" -type f -name "*.img" -o -name "*.tar.gz" -o -name "metadata.json" | while read -r file; do
    size=$(du -h "$file" | cut -f1)
    echo "  - $file ($size)"
done

echo ""
echo "To flash the image:"
echo "  sudo dd if=$DOWNLOAD_DIR/*/rpi5-k8s-*.img of=/dev/nvme0n1 bs=4M status=progress conv=fsync"
echo ""
