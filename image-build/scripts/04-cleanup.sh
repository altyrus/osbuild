#!/bin/bash
#
# 04-cleanup.sh - Cleanup and optimize the image
#
# This script removes temporary files, cleans package caches,
# and optimizes the image for minimal size.
#
# Usage: sudo ./04-cleanup.sh /path/to/root
#

set -euo pipefail

ROOT_PATH="${1:?Root path required}"

echo "=========================================="
echo "Cleaning up and optimizing image"
echo "Root path: ${ROOT_PATH}"
echo "=========================================="

# Verify root path
if [[ ! -d "${ROOT_PATH}" ]]; then
    echo "ERROR: Root path does not exist: ${ROOT_PATH}"
    exit 1
fi

echo "Cleaning apt cache..."
chroot "${ROOT_PATH}" apt-get clean
rm -rf "${ROOT_PATH}/var/lib/apt/lists/"*
rm -rf "${ROOT_PATH}/var/cache/apt/"*

echo "Cleaning temporary files..."
rm -rf "${ROOT_PATH}/tmp/"*
rm -rf "${ROOT_PATH}/var/tmp/"*

echo "Cleaning log files..."
find "${ROOT_PATH}/var/log" -type f -name "*.log" -delete
find "${ROOT_PATH}/var/log" -type f -name "*.gz" -delete
find "${ROOT_PATH}/var/log" -type f -name "*.old" -delete

echo "Cleaning user cache..."
rm -rf "${ROOT_PATH}/root/.cache"
rm -rf "${ROOT_PATH}/home/*/.cache" 2>/dev/null || true

echo "Cleaning SSH host keys..."
# These will be regenerated on first boot
rm -f "${ROOT_PATH}/etc/ssh/ssh_host_"*

echo "Cleaning machine-id..."
# This will be regenerated on first boot
truncate -s 0 "${ROOT_PATH}/etc/machine-id"
rm -f "${ROOT_PATH}/var/lib/dbus/machine-id"

echo "Removing QEMU static binary..."
rm -f "${ROOT_PATH}/usr/bin/qemu-aarch64-static"

echo "Removing bash history..."
rm -f "${ROOT_PATH}/root/.bash_history"
rm -f "${ROOT_PATH}/home/*/.bash_history" 2>/dev/null || true

echo "Cleaning package manager files..."
rm -f "${ROOT_PATH}/var/lib/dpkg/lock"*
rm -f "${ROOT_PATH}/var/cache/debconf/"*old

echo "Removing documentation to save space (optional)..."
# Uncomment if you want to save more space
# rm -rf "${ROOT_PATH}/usr/share/doc/"*
# rm -rf "${ROOT_PATH}/usr/share/man/"*
# rm -rf "${ROOT_PATH}/usr/share/info/"*

echo "Zeroing free space for better compression..."
# This helps compress the image better
dd if=/dev/zero of="${ROOT_PATH}/zero.file" bs=1M 2>/dev/null || true
rm -f "${ROOT_PATH}/zero.file"

echo "Disk usage summary:"
du -sh "${ROOT_PATH}"
df -h | grep -E 'Filesystem|/tmp/root'

echo "=========================================="
echo "Cleanup completed successfully"
echo "=========================================="
