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
chroot_exec apt-get update

echo "Installing prerequisites..."
chroot_exec apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    software-properties-common \
    git \
    jq \
    wget

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
chroot_exec apt-get install -y containerd

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
chroot_exec apt-get update
chroot_exec apt-get install -y \
    kubelet="${K8S_VERSION}-*" \
    kubeadm="${K8S_VERSION}-*" \
    kubectl="${K8S_VERSION}-*"

echo "Holding Kubernetes packages..."
chroot_exec apt-mark hold kubelet kubeadm kubectl

echo "Disabling kubelet (will be enabled after provisioning)..."
chroot_exec systemctl disable kubelet

echo "Installing CNI plugins..."
mkdir -p "${ROOT_PATH}/opt/cni/bin"
CNI_VERSION="v1.4.0"
curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-arm64-${CNI_VERSION}.tgz" | \
    tar -C "${ROOT_PATH}/opt/cni/bin" -xz

echo "Installing crictl..."
CRICTL_VERSION="v1.28.0"
curl -L "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-arm64.tar.gz" | \
    tar -C "${ROOT_PATH}/usr/local/bin" -xz

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
