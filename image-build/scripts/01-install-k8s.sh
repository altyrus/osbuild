#!/bin/bash
#
# 01-install-k8s.sh - Install Kubernetes components in the image
#
# This script runs in the GitHub Actions environment and installs
# Kubernetes packages into the mounted root filesystem.
#
# Usage: sudo ./01-install-k8s.sh /path/to/root K8S_VERSION
#

set -euo pipefail

ROOT_PATH="${1:?Root path required}"
K8S_VERSION="${2:-1.28.0}"

echo "=========================================="
echo "Installing Kubernetes ${K8S_VERSION}"
echo "Root path: ${ROOT_PATH}"
echo "=========================================="

# Verify root path
if [[ ! -d "${ROOT_PATH}" ]]; then
    echo "ERROR: Root path does not exist: ${ROOT_PATH}"
    exit 1
fi

# Use chroot helper function
chroot_exec() {
    chroot "${ROOT_PATH}" /bin/bash -c "$*"
}

# Mount necessary filesystems for chroot
mount_chroot() {
    mount -t proc /proc "${ROOT_PATH}/proc"
    mount -t sysfs /sys "${ROOT_PATH}/sys"
    mount --bind /dev "${ROOT_PATH}/dev"
    mount --bind /dev/pts "${ROOT_PATH}/dev/pts"
}

unmount_chroot() {
    umount "${ROOT_PATH}/dev/pts" || true
    umount "${ROOT_PATH}/dev" || true
    umount "${ROOT_PATH}/sys" || true
    umount "${ROOT_PATH}/proc" || true
}

# Trap cleanup
trap unmount_chroot EXIT

echo "Mounting proc, sys, dev for chroot..."
mount_chroot

echo "Setting up QEMU ARM64 emulation..."
cp /usr/bin/qemu-aarch64-static "${ROOT_PATH}/usr/bin/" || true

echo "Updating package lists..."
for i in 1 2 3; do
    echo "Running apt-get update (attempt $i)..."
    if chroot_exec apt-get update; then
        break
    fi
    [ $i -eq 3 ] && { echo "ERROR: apt-get update failed after 3 attempts"; exit 1; }
    echo "Cleaning apt cache and retrying..."
    chroot_exec apt-get clean
    sleep 5
done

echo "Installing prerequisites..."
for i in 1 2 3; do
    echo "Installing prerequisites (attempt $i)..."
    if chroot_exec apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        git \
        jq \
        wget; then
        break
    fi
    [ $i -eq 3 ] && { echo "ERROR: Failed to install prerequisites after 3 attempts"; exit 1; }
    echo "Cleaning apt cache and retrying..."
    chroot_exec apt-get clean
    chroot_exec apt-get update || true
    sleep 5
done

echo "Disabling swap..."
chroot_exec systemctl mask swap.target || true
chroot_exec swapoff -a || true
sed -i '/ swap / s/^\(.*\)$/#\1/g' "${ROOT_PATH}/etc/fstab"

echo "Enabling required kernel modules..."
cat >> "${ROOT_PATH}/etc/modules-load.d/k8s.conf" <<EOF
overlay
br_netfilter
EOF

echo "Configuring sysctl for Kubernetes..."
cat >> "${ROOT_PATH}/etc/sysctl.d/k8s.conf" <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

echo "Installing containerd..."
for i in 1 2 3; do
    echo "Installing containerd (attempt $i)..."
    if chroot_exec apt-get install -y containerd; then
        break
    fi
    [ $i -eq 3 ] && { echo "ERROR: Failed to install containerd after 3 attempts"; exit 1; }
    echo "Cleaning apt cache and retrying..."
    chroot_exec apt-get clean
    chroot_exec apt-get update || true
    sleep 5
done

echo "Configuring containerd..."
mkdir -p "${ROOT_PATH}/etc/containerd"
chroot_exec containerd config default > "${ROOT_PATH}/etc/containerd/config.toml"

# Enable SystemdCgroup
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "${ROOT_PATH}/etc/containerd/config.toml"

echo "Enabling containerd service..."
chroot_exec systemctl enable containerd

echo "Adding Kubernetes apt repository..."
mkdir -p "${ROOT_PATH}/etc/apt/keyrings"

# Download Kubernetes signing key
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}/deb/Release.key" | \
    gpg --dearmor -o "${ROOT_PATH}/etc/apt/keyrings/kubernetes-apt-keyring.gpg"

# Add Kubernetes repository
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}/deb/ /" | \
    tee "${ROOT_PATH}/etc/apt/sources.list.d/kubernetes.list"

echo "Installing Kubernetes packages..."
for i in 1 2 3; do
    echo "Running apt-get update (attempt $i)..."
    if chroot_exec apt-get update; then
        break
    fi
    [ $i -eq 3 ] && { echo "ERROR: apt-get update failed after 3 attempts"; exit 1; }
    echo "Cleaning apt cache and retrying..."
    chroot_exec apt-get clean
    sleep 5
done

for i in 1 2 3; do
    echo "Installing Kubernetes packages (attempt $i)..."
    if chroot_exec apt-get install -y \
        kubelet="${K8S_VERSION}-*" \
        kubeadm="${K8S_VERSION}-*" \
        kubectl="${K8S_VERSION}-*"; then
        break
    fi
    [ $i -eq 3 ] && { echo "ERROR: Failed to install Kubernetes packages after 3 attempts"; exit 1; }
    echo "Cleaning apt cache and retrying..."
    chroot_exec apt-get clean
    chroot_exec apt-get update || true
    sleep 5
done

echo "Holding Kubernetes packages..."
chroot_exec apt-mark hold kubelet kubeadm kubectl

echo "Disabling kubelet (will be enabled after provisioning)..."
chroot_exec systemctl disable kubelet

echo "Installing CNI plugins..."
mkdir -p "${ROOT_PATH}/opt/cni/bin"
CNI_VERSION="v1.4.0"
CNI_URL="https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-arm64-${CNI_VERSION}.tgz"

for i in 1 2 3; do
    echo "Downloading CNI plugins (attempt $i)..."
    if curl --retry 3 --retry-delay 2 --fail -L "$CNI_URL" -o /tmp/cni.tgz; then
        tar -C "${ROOT_PATH}/opt/cni/bin" -xzf /tmp/cni.tgz
        rm /tmp/cni.tgz
        break
    fi
    [ $i -eq 3 ] && { echo "ERROR: Failed to download CNI plugins after 3 attempts"; exit 1; }
    sleep 5
done

echo "Installing crictl..."
CRICTL_VERSION="v1.28.0"
CRICTL_URL="https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-arm64.tar.gz"

for i in 1 2 3; do
    echo "Downloading crictl (attempt $i)..."
    if curl --retry 3 --retry-delay 2 --fail -L "$CRICTL_URL" -o /tmp/crictl.tar.gz; then
        tar -C "${ROOT_PATH}/usr/local/bin" -xzf /tmp/crictl.tar.gz
        rm /tmp/crictl.tar.gz
        break
    fi
    [ $i -eq 3 ] && { echo "ERROR: Failed to download crictl after 3 attempts"; exit 1; }
    sleep 5
done

echo "Configuring crictl..."
cat > "${ROOT_PATH}/etc/crictl.yaml" <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

echo "=========================================="
echo "Kubernetes installation completed"
echo "Installed versions:"
chroot_exec dpkg -l | grep -E 'kubelet|kubeadm|kubectl'
echo "=========================================="
