#!/bin/bash
#
# common.sh - Shared functions for image builds
#

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}==>${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}WARNING:${NC} $*"
}

log_error() {
    echo -e "${RED}ERROR:${NC} $*" >&2
}

# Setup chroot environment
setup_chroot() {
    local root_path="$1"
    log_info "Mounting proc, sys, dev for chroot..."
    mount -t proc /proc "${root_path}/proc"
    mount -t sysfs /sys "${root_path}/sys"
    mount --bind /dev "${root_path}/dev"
    mount --bind /dev/pts "${root_path}/dev/pts"
}

# Cleanup chroot environment
cleanup_chroot() {
    local root_path="$1"
    log_info "Unmounting chroot filesystems..."
    umount "${root_path}/dev/pts" || true
    umount "${root_path}/dev" || true
    umount "${root_path}/sys" || true
    umount "${root_path}/proc" || true
}

# Execute command in chroot
chroot_exec() {
    local root_path="$1"
    shift
    chroot "${root_path}" /bin/bash -c "$*"
}

# Retry apt operations
apt_retry() {
    local root_path="$1"
    local operation="$2"
    shift 2

    for i in 1 2 3; do
        log_info "${operation} (attempt $i)..."
        if chroot_exec "${root_path}" "$@"; then
            return 0
        fi
        [ $i -eq 3 ] && { log_error "${operation} failed after 3 attempts"; return 1; }
        log_warn "Retrying ${operation}..."
        chroot_exec "${root_path}" "apt-get clean"
        sleep 5
    done
}

# Disable swap for Kubernetes
disable_swap() {
    local root_path="$1"
    log_info "Disabling swap..."
    chroot_exec "${root_path}" "systemctl mask swap.target" || true
    chroot_exec "${root_path}" "swapoff -a" || true
    sed -i '/ swap / s/^\(.*\)$/#\1/g' "${root_path}/etc/fstab"
}

# Configure kernel modules for Kubernetes
configure_k8s_modules() {
    local root_path="$1"
    log_info "Configuring kernel modules for Kubernetes..."
    cat >> "${root_path}/etc/modules-load.d/k8s.conf" <<EOF
overlay
br_netfilter
EOF
}

# Configure sysctl for Kubernetes
configure_k8s_sysctl() {
    local root_path="$1"
    log_info "Configuring sysctl for Kubernetes..."
    cat >> "${root_path}/etc/sysctl.d/k8s.conf" <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
}

# Safe sync and unmount
safe_unmount() {
    local mount_point="$1"
    log_info "Syncing and unmounting ${mount_point}..."
    sync
    sleep 2
    umount "${mount_point}" || umount -l "${mount_point}" || true
}

# Get loop device UUID
get_partition_uuid() {
    local device="$1"
    blkid "${device}" | grep -oP 'UUID="\K[^"]+'
}
