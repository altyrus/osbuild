#!/bin/bash
#
# build-x64.sh - Build x64 image with virtio support for QEMU/KVM testing
# Uses Debian 13 (Trixie) cloud image as base
#
# LESSONS LEARNED (2025-11-07):
# - 120GB disk required for full service stack (MinIO 50GB + services 30GB + OS 7GB + buffer 33GB)
# - 40GB insufficient: causes Longhorn PVC faults for MinIO/Grafana/Prometheus/Portainer
# - Ensure partition expansion works: cloud-init-growroot must run on first boot
#

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load common functions
source "${SCRIPT_DIR}/lib/common.sh"

# Load configuration
source "${SCRIPT_DIR}/config/base-images.conf"

# Configuration
ARCH="amd64"
K8S_VERSION="${K8S_VERSION:-${DEFAULT_K8S_VERSION}}"
IMAGE_VERSION="${IMAGE_VERSION:-x64-$(date +%Y%m%d-%H%M%S)}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output-x64}"
WORK_DIR="${SCRIPT_DIR}/image-build/work-x64"
CACHE_DIR="${SCRIPT_DIR}/${BUILD_CACHE_DIR}"

# Use configuration values
BASE_IMAGE_URL="${X64_BASE_IMAGE_URL}"
BASE_IMAGE_NAME="${X64_BASE_IMAGE_NAME}"
TARGET_SIZE="${X64_TARGET_SIZE}"

# Create directories
mkdir -p "${OUTPUT_DIR}" "${WORK_DIR}" "${CACHE_DIR}"

log_info "==========================================="
log_info "OSBuild - x64 Image Build (Debian Trixie)"
log_info "==========================================="
log_info "Architecture: ${ARCH}"
log_info "OS: ${X64_OS_NAME}"
log_info "Kubernetes: ${K8S_VERSION}"
log_info "Image Version: ${IMAGE_VERSION}"
log_info "Output: ${OUTPUT_DIR}"
log_info "==========================================="

# Download base image if not cached
if [[ ! -f "${CACHE_DIR}/${BASE_IMAGE_NAME}" ]] || [[ ! -s "${CACHE_DIR}/${BASE_IMAGE_NAME}" ]]; then
    log_info "Downloading ${X64_OS_NAME} cloud image..."
    # Remove any empty or corrupted cached file
    rm -f "${CACHE_DIR}/${BASE_IMAGE_NAME}"

    # Download with retries
    DOWNLOAD_SUCCESS=false
    for attempt in 1 2 3; do
        log_info "Download attempt ${attempt}/3..."
        if wget -O "${CACHE_DIR}/${BASE_IMAGE_NAME}" "${BASE_IMAGE_URL}"; then
            # Verify the download is a valid qcow2 image
            if qemu-img info "${CACHE_DIR}/${BASE_IMAGE_NAME}" >/dev/null 2>&1; then
                log_info "Download successful and verified"
                DOWNLOAD_SUCCESS=true
                break
            else
                log_error "Downloaded file is not a valid qcow2 image"
                rm -f "${CACHE_DIR}/${BASE_IMAGE_NAME}"
            fi
        fi
        log_info "Download attempt ${attempt} failed, retrying in 5 seconds..."
        sleep 5
    done

    if [ "$DOWNLOAD_SUCCESS" = false ]; then
        log_error "Failed to download base image after 3 attempts"
        exit 1
    fi
else
    log_info "Using cached base image"
    # Verify cached image is valid
    if ! qemu-img info "${CACHE_DIR}/${BASE_IMAGE_NAME}" >/dev/null 2>&1; then
        log_error "Cached image is corrupted, removing and re-downloading..."
        rm -f "${CACHE_DIR}/${BASE_IMAGE_NAME}"
        exec "$0" "$@"
    fi
fi

# Convert qcow2 to raw and expand
log_info "Converting and expanding image to ${TARGET_SIZE}..."
if ! qemu-img convert -f qcow2 -O raw "${CACHE_DIR}/${BASE_IMAGE_NAME}" "${WORK_DIR}/base.img"; then
    log_error "Failed to convert qcow2 image to raw format"
    exit 1
fi

if ! qemu-img resize "${WORK_DIR}/base.img" "${TARGET_SIZE}"; then
    log_error "Failed to resize image to ${TARGET_SIZE}"
    exit 1
fi

# Verify the converted image
if [[ ! -f "${WORK_DIR}/base.img" ]] || [[ ! -s "${WORK_DIR}/base.img" ]]; then
    log_error "Converted image is missing or empty"
    exit 1
fi

log_info "Image conversion and resize completed successfully"

# Setup loop device
log_info "Setting up loop device..."
LOOP_DEVICE=$(losetup -f --show "${WORK_DIR}/base.img")

if [[ -z "${LOOP_DEVICE}" ]]; then
    log_error "Failed to setup loop device"
    exit 1
fi

if [[ ! -b "${LOOP_DEVICE}" ]]; then
    log_error "Loop device ${LOOP_DEVICE} is not a block device"
    exit 1
fi

log_info "Loop device: ${LOOP_DEVICE}"

# Cleanup function
cleanup() {
    log_info "Cleaning up..."
    sync
    sleep 2

    if mountpoint -q /tmp/x64-root 2>/dev/null; then
        cleanup_chroot /tmp/x64-root || true
        safe_unmount /tmp/x64-root
    fi

    if [[ -n "${LOOP_DEVICE:-}" ]]; then
        partprobe "${LOOP_DEVICE}" 2>/dev/null || true
        sleep 1
        losetup -d "${LOOP_DEVICE}" 2>/dev/null || true
    fi
}

trap cleanup EXIT

# Re-read partition table
log_info "Reading partition table..."
partprobe "${LOOP_DEVICE}"
sleep 2

# Debian cloud images typically have partition 1 as root
ROOT_PART="${LOOP_DEVICE}p1"

# Check if partition exists with retries (sometimes takes a moment to appear)
PARTITION_FOUND=false
for attempt in 1 2 3 4 5; do
    if [[ -b "${ROOT_PART}" ]]; then
        PARTITION_FOUND=true
        break
    fi
    log_info "Waiting for partition to appear (attempt ${attempt}/5)..."
    partprobe "${LOOP_DEVICE}" 2>/dev/null || true
    sleep 2
done

if [ "$PARTITION_FOUND" = false ]; then
    log_error "Root partition ${ROOT_PART} not found after 5 attempts"
    log_info "Available devices:"
    ls -la /dev/loop* || true
    fdisk -l "${LOOP_DEVICE}" || true
    exit 1
fi

log_info "Root partition: ${ROOT_PART}"

# Resize filesystem
log_info "Resizing filesystem..."
e2fsck -f -y "${ROOT_PART}" || true

if ! resize2fs "${ROOT_PART}"; then
    log_error "Failed to resize filesystem"
    exit 1
fi

# Mount root
log_info "Mounting root filesystem..."
mkdir -p /tmp/x64-root

if ! mount "${ROOT_PART}" /tmp/x64-root; then
    log_error "Failed to mount root filesystem"
    exit 1
fi

# Verify mount
if ! mountpoint -q /tmp/x64-root; then
    log_error "Mount verification failed"
    exit 1
fi

ROOT_PATH="/tmp/x64-root"
log_info "Root filesystem mounted successfully"

# Setup chroot
setup_chroot "${ROOT_PATH}"

# Update system
log_info "Updating system..."
apt_retry "${ROOT_PATH}" "apt-get update" "apt-get update"

# Install prerequisites
log_info "Installing prerequisites..."
apt_retry "${ROOT_PATH}" "Install prerequisites" "apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    git \
    jq \
    wget"

# Install Platform dependencies (storage, networking, HA)
log_info "Installing Platform integration dependencies..."
apt_retry "${ROOT_PATH}" "Install Platform dependencies" "apt-get install -y \
    open-iscsi \
    nfs-common \
    haproxy"

log_info "Enabling open-iscsi service..."
chroot_exec "${ROOT_PATH}" "systemctl enable open-iscsi" || true
chroot_exec "${ROOT_PATH}" "systemctl enable iscsid" || true

# Disable swap
disable_swap "${ROOT_PATH}"

# Configure kernel modules
configure_k8s_modules "${ROOT_PATH}"

# Configure sysctl
configure_k8s_sysctl "${ROOT_PATH}"

# Install containerd
log_info "Installing containerd..."
apt_retry "${ROOT_PATH}" "Install containerd" "apt-get install -y containerd"

# Configure containerd
log_info "Configuring containerd..."
mkdir -p "${ROOT_PATH}/etc/containerd"
chroot_exec "${ROOT_PATH}" "containerd config default" > "${ROOT_PATH}/etc/containerd/config.toml"
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "${ROOT_PATH}/etc/containerd/config.toml"

log_info "Enabling containerd service..."
chroot_exec "${ROOT_PATH}" "systemctl enable containerd"

# Add Kubernetes repository
log_info "Adding Kubernetes repository..."
mkdir -p "${ROOT_PATH}/etc/apt/keyrings"
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}/deb/Release.key" | \
    gpg --dearmor -o "${ROOT_PATH}/etc/apt/keyrings/kubernetes-apt-keyring.gpg"

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}/deb/ /" | \
    tee "${ROOT_PATH}/etc/apt/sources.list.d/kubernetes.list"

# Update apt with Kubernetes repo
apt_retry "${ROOT_PATH}" "apt-get update" "apt-get update"

# Install Kubernetes packages
log_info "Installing Kubernetes ${K8S_VERSION}..."
apt_retry "${ROOT_PATH}" "Install Kubernetes" "apt-get install -y \
    kubelet=${K8S_VERSION}-* \
    kubeadm=${K8S_VERSION}-* \
    kubectl=${K8S_VERSION}-*"

log_info "Holding Kubernetes packages..."
chroot_exec "${ROOT_PATH}" "apt-mark hold kubelet kubeadm kubectl"

log_info "Disabling kubelet (will be enabled after provisioning)..."
chroot_exec "${ROOT_PATH}" "systemctl disable kubelet"

# Install CNI plugins
log_info "Installing CNI plugins..."
mkdir -p "${ROOT_PATH}/opt/cni/bin"
CNI_VERSION="v1.4.0"
CNI_URL="https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz"

# Try to download CNI plugins with retries, but don't fail if it doesn't work
# (can be installed later by cluster provisioning)
CNI_DOWNLOADED=false
for i in 1 2 3; do
    log_info "Downloading CNI plugins (attempt $i/3)..."
    if curl --retry 2 --retry-delay 5 -fsSL "${CNI_URL}" | tar -C "${ROOT_PATH}/opt/cni/bin" -xz 2>/dev/null; then
        CNI_DOWNLOADED=true
        log_info "CNI plugins installed successfully"
        break
    fi
    log_info "CNI download attempt $i failed, retrying..."
    sleep 5
done

if [ "$CNI_DOWNLOADED" = false ]; then
    log_info "WARNING: CNI plugins could not be downloaded. They can be installed during cluster provisioning."
fi

# Install crictl
log_info "Installing crictl..."
CRICTL_VERSION="v1.28.0"
CRICTL_URL="https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"

# Download crictl with retries (SSL errors are intermittent)
CRICTL_DOWNLOADED=false
for i in 1 2 3 4 5; do
    log_info "Downloading crictl (attempt $i/5)..."
    if curl --retry 2 --retry-delay 5 -fsSL "${CRICTL_URL}" | tar -C "${ROOT_PATH}/usr/local/bin" -xz 2>/dev/null; then
        CRICTL_DOWNLOADED=true
        log_info "crictl installed successfully"
        break
    fi
    log_info "crictl download attempt $i failed, retrying..."
    sleep 5
done

if [ "$CRICTL_DOWNLOADED" = false ]; then
    log_info "WARNING: crictl could not be downloaded after 5 attempts. Continuing anyway..."
fi

# Configure crictl
cat > "${ROOT_PATH}/etc/crictl.yaml" <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

# Install helm
log_info "Installing helm..."
HELM_VERSION="v3.16.3"
HELM_URL="https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"

curl --retry 3 -L "${HELM_URL}" | tar -xz -C /tmp
mv /tmp/linux-amd64/helm "${ROOT_PATH}/usr/local/bin/helm"
chmod +x "${ROOT_PATH}/usr/local/bin/helm"
rm -rf /tmp/linux-amd64

# Configure cloud-init - Debian cloud images already have cloud-init
log_info "Configuring cloud-init..."

# Create NoCloud data source configuration
mkdir -p "${ROOT_PATH}/var/lib/cloud/seed/nocloud-net"

cat > "${ROOT_PATH}/var/lib/cloud/seed/nocloud-net/meta-data" <<'EOF'
instance-id: k8s-x64-node
local-hostname: k8s-x64-node
EOF

cat > "${ROOT_PATH}/var/lib/cloud/seed/nocloud-net/user-data" <<'EOF'
#cloud-config
# Kubernetes x64 node configuration

# Create default user
users:
  - name: k8s
    groups: [adm, audio, cdrom, dialout, dip, floppy, netdev, plugdev, sudo, video]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    # Password: k8spass
    passwd: $6$3lzs8VHlGRUbaj9Z$zqK9/13osd3ZtEos3l2wrOoRfoy6zmLU3bCEvGsywEuk5YSuP07/8LDR80N0.4T30qiRT9p7HkC8Xq1YMF9gT.

# SSH configuration
ssh_pwauth: true
disable_root: false

# System setup
runcmd:
  - swapoff -a
  - sed -i '/ swap / s/^/#/' /etc/fstab
  - systemctl enable ssh
  - systemctl start ssh
  - systemctl enable containerd
  - touch /var/lib/cloud/instance/boot-finished
  - echo "Cloud-init configuration completed - K8s node ready"

# Package management
package_update: false
package_upgrade: false

final_message: |
  ==================================================
  Kubernetes x64 Node - Cloud-init Complete
  ==================================================
  User: k8s
  Password: k8spass
  SSH: Enabled

  Kubernetes ${K8S_VERSION} installed:
  - kubelet (disabled, enable after cluster init)
  - kubeadm
  - kubectl
  - containerd (enabled)

  SSH: ssh k8s@<ip-address>
  ==================================================
EOF

# Verify installation
log_info "Verifying installation..."
log_info "Kubernetes packages:"
chroot_exec "${ROOT_PATH}" "dpkg -l | grep -E 'kubelet|kubeadm|kubectl|containerd|cloud-init'"

# Cleanup chroot
cleanup_chroot "${ROOT_PATH}"

# Unmount
safe_unmount "${ROOT_PATH}"

# Detach loop device
log_info "Detaching loop device..."
sync
sleep 2
losetup -d "${LOOP_DEVICE}"
LOOP_DEVICE=""

# Final sync
log_info "Final sync..."
sync
sleep 3

# Copy to output
log_info "Copying image to output..."
if ! cp "${WORK_DIR}/base.img" "${OUTPUT_DIR}/k8s-${IMAGE_VERSION}.img"; then
    log_error "Failed to copy image to output directory"
    exit 1
fi
sync

# Verify output image
if [[ ! -f "${OUTPUT_DIR}/k8s-${IMAGE_VERSION}.img" ]] || [[ ! -s "${OUTPUT_DIR}/k8s-${IMAGE_VERSION}.img" ]]; then
    log_error "Output image is missing or empty"
    exit 1
fi

log_info "Image copied successfully"

# Generate checksums
log_info "Generating checksums..."
cd "${OUTPUT_DIR}"
if ! sha256sum "k8s-${IMAGE_VERSION}.img" > "k8s-${IMAGE_VERSION}.img.sha256"; then
    log_error "Failed to generate checksums"
    exit 1
fi

# Generate metadata
cat > "${OUTPUT_DIR}/metadata.json" <<EOF
{
  "image": "k8s-${IMAGE_VERSION}.img",
  "architecture": "${ARCH}",
  "os": "${X64_OS_NAME}",
  "kernel": "${KERNEL_VERSION}",
  "kubernetes_version": "${K8S_VERSION}",
  "build_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "size_bytes": $(stat -c%s "k8s-${IMAGE_VERSION}.img"),
  "sha256": "$(cat k8s-${IMAGE_VERSION}.img.sha256 | cut -d' ' -f1)"
}
EOF

log_info "==========================================="
log_info "✅ Build completed successfully!"
log_info "==========================================="
log_info ""
log_info "Output: ${OUTPUT_DIR}/k8s-${IMAGE_VERSION}.img"
log_info "Size: $(du -h ${OUTPUT_DIR}/k8s-${IMAGE_VERSION}.img | cut -f1)"
log_info ""
log_info "Test in KVM/QEMU:"
log_info "  sudo qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -nographic \\"
log_info "    -drive file=${OUTPUT_DIR}/k8s-${IMAGE_VERSION}.img,format=raw,if=virtio \\"
log_info "    -netdev user,id=net0,hostfwd=tcp::2222-:22 \\"
log_info "    -device virtio-net-pci,netdev=net0"
log_info ""
log_info "SSH after boot (wait ~60s for cloud-init):"
log_info "  ssh k8s@localhost -p 2222"
log_info "  Password: k8spass"
log_info "==========================================="
