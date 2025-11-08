#!/bin/bash
#
# 02-install-cloudinit.sh - Install and configure cloud-init
#
# This script installs cloud-init and configures it for first-boot
# auto-provisioning. Replaces the custom bootstrap framework.
#
# Usage: sudo ./02-install-cloudinit.sh /path/to/root
#

set -euo pipefail

ROOT_PATH="${1:?Root path required}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$(dirname "${SCRIPT_DIR}")/files"

echo "=========================================="
echo "Installing cloud-init"
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

# Install cloud-init package
echo "Installing cloud-init package..."
chroot "${ROOT_PATH}" apt-get update
chroot "${ROOT_PATH}" apt-get install -y cloud-init cloud-guest-utils

# Copy cloud-init configuration files to boot partition
# Note: Boot partition will be mounted at /boot/firmware in the final image
echo "Preparing cloud-init configuration..."
mkdir -p "${ROOT_PATH}/boot/firmware/cloud-init"

# Copy user-data and meta-data
if [[ -f "${FILES_DIR}/cloud-init/user-data" ]]; then
    cp "${FILES_DIR}/cloud-init/user-data" "${ROOT_PATH}/boot/firmware/user-data"
    echo "Copied user-data to boot partition"
else
    echo "WARNING: user-data not found at ${FILES_DIR}/cloud-init/user-data"
fi

if [[ -f "${FILES_DIR}/cloud-init/meta-data" ]]; then
    cp "${FILES_DIR}/cloud-init/meta-data" "${ROOT_PATH}/boot/firmware/meta-data"
    echo "Copied meta-data to boot partition"
else
    echo "WARNING: meta-data not found at ${FILES_DIR}/cloud-init/meta-data"
fi

# Configure cloud-init datasources
echo "Configuring cloud-init datasources..."
cat > "${ROOT_PATH}/etc/cloud/cloud.cfg.d/99_nocloud.cfg" <<'EOF'
# Use NoCloud datasource to read from boot partition
datasource_list: [ NoCloud, None ]
datasource:
  NoCloud:
    # Look for user-data and meta-data in /boot/firmware/
    seedfrom: /boot/firmware/
    fs_label: null
EOF

# Configure cloud-init to run on first boot
echo "Configuring cloud-init for first boot..."
cat > "${ROOT_PATH}/etc/cloud/cloud.cfg.d/99_first_boot.cfg" <<'EOF'
# Ensure cloud-init runs on first boot
cloud_init_modules:
 - migrator
 - seed_random
 - bootcmd
 - write-files
 - growpart
 - resizefs
 - disk_setup
 - mounts
 - set_hostname
 - update_hostname
 - update_etc_hosts
 - ca-certs
 - rsyslog
 - users-groups
 - ssh

cloud_config_modules:
 - emit_upstart
 - snap
 - ssh-import-id
 - locale
 - set-passwords
 - grub-dpkg
 - apt-pipelining
 - apt-configure
 - ubuntu-advantage
 - ntp
 - timezone
 - disable-ec2-metadata
 - runcmd
 - byobu

cloud_final_modules:
 - package-update-upgrade-install
 - fan
 - landscape
 - lxd
 - ubuntu-drivers
 - write-files-deferred
 - puppet
 - chef
 - mcollective
 - salt-minion
 - reset_rmc
 - refresh_rmc_and_interface
 - rightscale_userdata
 - scripts-vendor
 - scripts-per-once
 - scripts-per-boot
 - scripts-per-instance
 - scripts-user
 - ssh-authkey-fingerprints
 - keys-to-console
 - phone-home
 - final-message
 - power-state-change
EOF

# Disable network configuration by cloud-init (we'll handle it manually if needed)
echo "network: {config: disabled}" > "${ROOT_PATH}/etc/cloud/cloud.cfg.d/99_disable_network_config.cfg"

# Enable cloud-init services
echo "Enabling cloud-init services..."
chroot "${ROOT_PATH}" systemctl enable cloud-init-local.service || true
chroot "${ROOT_PATH}" systemctl enable cloud-init.service || true
chroot "${ROOT_PATH}" systemctl enable cloud-config.service || true
chroot "${ROOT_PATH}" systemctl enable cloud-final.service || true

# Clean cloud-init state to ensure it runs on first boot
echo "Cleaning cloud-init state..."
chroot "${ROOT_PATH}" cloud-init clean --logs || true

# Create first-boot marker
touch "${ROOT_PATH}/etc/first-boot-marker"

echo "=========================================="
echo "Cloud-init installation completed successfully"
echo "=========================================="
