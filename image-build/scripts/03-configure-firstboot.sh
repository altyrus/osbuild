#!/bin/bash
#
# 03-configure-firstboot.sh - Configure first-boot behavior
#
# This script configures additional first-boot settings
# and ensures everything is ready for automatic provisioning.
#
# Usage: sudo ./03-configure-firstboot.sh /path/to/root
#

set -euo pipefail

ROOT_PATH="${1:?Root path required}"

echo "=========================================="
echo "Configuring first-boot settings"
echo "Root path: ${ROOT_PATH}"
echo "=========================================="

# Verify root path
if [[ ! -d "${ROOT_PATH}" ]]; then
    echo "ERROR: Root path does not exist: ${ROOT_PATH}"
    exit 1
fi

echo "Configuring network wait..."
chroot "${ROOT_PATH}" systemctl enable systemd-networkd-wait-online.service || true

echo "Configuring SSH..."
# Enable SSH
chroot "${ROOT_PATH}" systemctl enable ssh || true

# Configure SSH to allow key-based auth
cat >> "${ROOT_PATH}/etc/ssh/sshd_config" <<EOF

# Custom configuration for automated provisioning
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
EOF

echo "Setting default locale..."
cat > "${ROOT_PATH}/etc/default/locale" <<EOF
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
EOF

echo "Configuring timezone (UTC)..."
ln -sf /usr/share/zoneinfo/UTC "${ROOT_PATH}/etc/localtime"

echo "Disabling unattended-upgrades during provisioning..."
# We'll control updates via our bootstrap scripts
chroot "${ROOT_PATH}" systemctl disable apt-daily.timer || true
chroot "${ROOT_PATH}" systemctl disable apt-daily-upgrade.timer || true

echo "Configuring journald..."
cat >> "${ROOT_PATH}/etc/systemd/journald.conf" <<EOF

# Limit journal size
SystemMaxUse=200M
RuntimeMaxUse=50M
EOF

echo "Creating version file..."
cat > "${ROOT_PATH}/etc/os-image-version" <<EOF
{
    "image_type": "raspberry-pi-5-kubernetes",
    "build_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "git_commit": "${GITHUB_SHA:-unknown}",
    "kubernetes_version": "${K8S_VERSION:-unknown}",
    "builder": "github-actions"
}
EOF

echo "Configuring boot config..."
# Enable container features in boot config
if [[ -f "${ROOT_PATH}/boot/config.txt" ]] || [[ -f "${ROOT_PATH}/boot/firmware/config.txt" ]]; then
    BOOT_CONFIG="${ROOT_PATH}/boot/config.txt"
    [[ ! -f "$BOOT_CONFIG" ]] && BOOT_CONFIG="${ROOT_PATH}/boot/firmware/config.txt"

    if [[ -f "$BOOT_CONFIG" ]]; then
        echo "" >> "$BOOT_CONFIG"
        echo "# Enable cgroups for Kubernetes" >> "$BOOT_CONFIG"
        grep -q "cgroup_memory=1" "$BOOT_CONFIG" || echo "cgroup_memory=1" >> "$BOOT_CONFIG"
        grep -q "cgroup_enable=memory" "$BOOT_CONFIG" || echo "cgroup_enable=memory" >> "$BOOT_CONFIG"
        grep -q "cgroup_enable=cpuset" "$BOOT_CONFIG" || echo "cgroup_enable=cpuset" >> "$BOOT_CONFIG"
    fi
fi

echo "Configuring cmdline..."
if [[ -f "${ROOT_PATH}/boot/cmdline.txt" ]] || [[ -f "${ROOT_PATH}/boot/firmware/cmdline.txt" ]]; then
    CMDLINE="${ROOT_PATH}/boot/cmdline.txt"
    [[ ! -f "$CMDLINE" ]] && CMDLINE="${ROOT_PATH}/boot/firmware/cmdline.txt"

    if [[ -f "$CMDLINE" ]]; then
        # Add cgroup parameters to kernel command line
        CURRENT_CMDLINE=$(cat "$CMDLINE")
        if ! echo "$CURRENT_CMDLINE" | grep -q "cgroup_memory=1"; then
            echo "$CURRENT_CMDLINE cgroup_memory=1 cgroup_enable=memory cgroup_enable=cpuset" > "$CMDLINE"
        fi
    fi
fi

echo "Setting hostname to temporary value..."
echo "rpi5-unconfigured" > "${ROOT_PATH}/etc/hostname"

echo "Configuring hosts file..."
cat > "${ROOT_PATH}/etc/hosts" <<EOF
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters

127.0.1.1       rpi5-unconfigured
EOF

echo "Creating first-boot marker..."
# This helps scripts detect if this is truly the first boot
touch "${ROOT_PATH}/etc/first-boot-marker"

echo "=========================================="
echo "First-boot configuration completed"
echo "=========================================="
