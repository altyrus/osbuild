#!/bin/bash
################################################################################
# Test Node1 with Cloud-LocalDS ISO (Like Platform Project)
#
# This test uses cloud-localds to create a cloud-init ISO like the platform
# project does, to compare against the NoCloud filesystem seed approach.
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
VM_NAME="zt-node1-iso-test"
NODE1_IP="192.168.100.11"
BASE_IMAGE="$SCRIPT_DIR/output/x64/zerotouch/k8s-node1.img"
SSH_KEY="$SCRIPT_DIR/output/x64/zerotouch/credentials/id_rsa"
SSH_PUB_KEY="${SSH_KEY}.pub"

log_info "=========================================="
log_info "Zero-Touch Test with Cloud-LocalDS ISO"
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

# Create test directory
TEST_DIR="/tmp/zt-iso-test"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

# Copy base image
VM_DISK="$TEST_DIR/${VM_NAME}.img"
log_info "Copying base image..."
cp "$BASE_IMAGE" "$VM_DISK"

# Create cloud-init user-data (simple version for testing)
log_info "Creating cloud-init configuration..."
SSH_PUB_KEY_CONTENT=$(cat "$SSH_PUB_KEY")

cat > "$TEST_DIR/user-data" <<EOF
#cloud-config
hostname: k8s-node1
fqdn: k8s-node1.local

users:
  - name: k8sadmin
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - $SSH_PUB_KEY_CONTENT

write_files:
  - path: /etc/netplan/01-netcfg.yaml
    permissions: '0644'
    content: |
      network:
        version: 2
        ethernets:
          enp1s0:
            dhcp4: false
            addresses:
              - 192.168.100.11/24
            gateway4: 192.168.100.1
            nameservers:
              addresses:
                - 8.8.8.8
                - 8.8.4.4

runcmd:
  - netplan apply
  - hostnamectl set-hostname k8s-node1

package_update: false
package_upgrade: false

power_state:
  mode: reboot
  timeout: 300
  condition: true
EOF

# Create meta-data
cat > "$TEST_DIR/meta-data" <<EOF
instance-id: $VM_NAME
local-hostname: k8s-node1
EOF

# Create cloud-init ISO using cloud-localds
CLOUD_INIT_ISO="$TEST_DIR/${VM_NAME}-cloud-init.iso"
log_info "Creating cloud-init ISO with cloud-localds..."
cloud-localds "$CLOUD_INIT_ISO" "$TEST_DIR/user-data" "$TEST_DIR/meta-data"

log_info "Cloud-init ISO created: $CLOUD_INIT_ISO"

# Create VM with virt-install (exactly like platform project)
log_info "Creating VM with virt-install..."
virt-install \
    --name "$VM_NAME" \
    --ram 16384 \
    --vcpus 4 \
    --disk path="$VM_DISK",format=raw,bus=virtio \
    --disk path="$CLOUD_INIT_ISO",device=cdrom \
    --network network="$NETWORK_NAME",model=virtio \
    --os-variant debian11 \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole \
    --import &

sleep 15

# Wait for SSH
log_info "Waiting for VM to boot and reboot (cloud-init will reboot)..."
log_info "This may take up to 2 minutes..."
sleep 60

log_info ""
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

if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       k8sadmin@$NODE1_IP "hostname && ip addr show | grep inet" 2>&1; then
    log_info ""
    log_info "=========================================="
    log_info "SUCCESS! Network is working!"
    log_info "=========================================="
else
    log_error "Failed to connect"
    exit 1
fi

log_info ""
log_info "To destroy test VM: virsh destroy $VM_NAME && virsh undefine $VM_NAME --remove-all-storage"
log_info "Test files in: $TEST_DIR"
