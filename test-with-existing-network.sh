#!/bin/bash
################################################################################
# Test Node1 with Existing Libvirt Network (k8s-network from platform)
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration
NETWORK_NAME="k8s-network"  # Use existing network from platform
VM_NAME="zt-node1"
NODE1_IP="192.168.100.11"
IMAGE_PATH="$SCRIPT_DIR/output-zerotouch-x64/k8s-node1.img"
SSH_KEY="$SCRIPT_DIR/output-zerotouch-x64/credentials/id_rsa"

log_info "=========================================="
log_info "Zero-Touch Test with k8s-network"
log_info "=========================================="
log_info "Network: $NETWORK_NAME"
log_info "Node IP: $NODE1_IP"
log_info "VM: $VM_NAME"
log_info ""

# Cleanup any existing VM
if virsh list --all | grep -q "$VM_NAME"; then
    log_info "Cleaning up existing VM..."
    virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
fi

# Copy image
LIBVIRT_IMAGE="/var/lib/libvirt/images/${VM_NAME}.img"
log_info "Copying image..."
sudo cp "$IMAGE_PATH" "$LIBVIRT_IMAGE"

# Create VM
log_info "Creating VM..."
sudo virt-install \
    --name "$VM_NAME" \
    --ram 16384 \
    --vcpus 4 \
    --disk path="$LIBVIRT_IMAGE",format=raw,bus=virtio \
    --network network="$NETWORK_NAME",model=virtio \
    --os-variant debian11 \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole \
    --import &

sleep 15

# Wait for SSH
log_info "Waiting for SSH on $NODE1_IP..."
for i in {1..60}; do
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=2 -o BatchMode=yes k8sadmin@$NODE1_IP "echo OK" &>/dev/null; then
        log_info "SSH Ready!"
        break
    fi
    echo -n "."
    sleep 5
done

echo ""
log_info "=========================================="
log_info "Network Verification"
log_info "=========================================="

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    k8sadmin@$NODE1_IP "hostname && ip addr show | grep 'inet.*192.168'"

log_info ""
log_info "Tailing bootstrap log (Ctrl-C to stop)..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    k8sadmin@$NODE1_IP "tail -f /var/log/bootstrap.log 2>/dev/null || tail -f /var/log/cloud-init-output.log"
