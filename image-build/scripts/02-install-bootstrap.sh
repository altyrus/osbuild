#!/bin/bash
#
# 02-install-bootstrap.sh - Install bootstrap framework
#
# This script installs the bootstrap scripts and configuration
# that will run on first boot.
#
# Usage: sudo ./02-install-bootstrap.sh /path/to/root
#

set -euo pipefail

ROOT_PATH="${1:?Root path required}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$(dirname "${SCRIPT_DIR}")/files"

echo "=========================================="
echo "Installing bootstrap framework"
echo "Root path: ${ROOT_PATH}"
echo "Files dir: ${FILES_DIR}"
echo "=========================================="

# Verify paths
if [[ ! -d "${ROOT_PATH}" ]]; then
    echo "ERROR: Root path does not exist: ${ROOT_PATH}"
    exit 1
fi

if [[ ! -d "${FILES_DIR}" ]]; then
    echo "ERROR: Files directory does not exist: ${FILES_DIR}"
    exit 1
fi

echo "Creating bootstrap directory..."
mkdir -p "${ROOT_PATH}/opt/bootstrap"

echo "Copying bootstrap script..."
cp "${FILES_DIR}/bootstrap/bootstrap.sh" "${ROOT_PATH}/opt/bootstrap/bootstrap.sh"
chmod +x "${ROOT_PATH}/opt/bootstrap/bootstrap.sh"

echo "Creating log directory..."
mkdir -p "${ROOT_PATH}/var/log"
touch "${ROOT_PATH}/var/log/bootstrap.log"

echo "Creating state directory..."
mkdir -p "${ROOT_PATH}/var/lib"

echo "Installing first-boot systemd service..."
cp "${FILES_DIR}/systemd/first-boot.service" "${ROOT_PATH}/etc/systemd/system/first-boot.service"

echo "Enabling first-boot service..."
chroot "${ROOT_PATH}" systemctl enable first-boot.service

echo "Creating bootstrap configuration file..."
cat > "${ROOT_PATH}/etc/bootstrap.conf" <<EOF
# Bootstrap configuration
# This file can be customized during image build or at runtime

# Git repository containing bootstrap scripts
BOOTSTRAP_REPO="https://github.com/altyrus/k8s-bootstrap.git"
BOOTSTRAP_BRANCH="main"

# Optional: Configuration endpoint for node registration
# CONFIG_ENDPOINT="https://bootstrap.yourdomain.com/config"

# Optional: Custom environment
# ENVIRONMENT="production"
EOF

echo "Creating motd banner..."
cat > "${ROOT_PATH}/etc/motd" <<'EOF'

   ____  ____  ____        _ __    __
  / __ \/ __ \/ __ )__  __(_) /___/ /
 / / / / /_/ / __  / / / / / / __  /
/ /_/ / ____/ /_/ / /_/ / / / /_/ /
\____/_/   /_____/\__,_/_/_/\__,_/

Raspberry Pi 5 Kubernetes Node
Auto-provisioning enabled

First boot: Node will automatically provision and join the cluster
Check status: systemctl status first-boot.service
View logs: journalctl -u first-boot.service

EOF

echo "=========================================="
echo "Bootstrap framework installed successfully"
echo "=========================================="
