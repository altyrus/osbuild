#!/bin/bash
################################################################################
# Test Node1 with Libvirt Bridge Network (Like Platform Project)
#
# Creates a libvirt NAT network and boots node1 with proper networking
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# Network configuration (matching platform project)
NETWORK_NAME="k8s-zerotouch-test"
BRIDGE_NAME="virbr-zt"
PRIVATE_SUBNET="192.168.100.0/24"
PRIVATE_GATEWAY="192.168.100.1"
NODE1_IP="192.168.100.11"

# VM configuration
VM_NAME="k8s-zerotouch-node1"
IMAGE_PATH="$SCRIPT_DIR/output/x64/zerotouch/k8s-node1.img"
SSH_KEY="$SCRIPT_DIR/output/x64/zerotouch/credentials/id_rsa"

log_info "=========================================="
log_info "Zero-Touch Node1 Test with Libvirt"
log_info "=========================================="
log_info "Network: $NETWORK_NAME"
log_info "Bridge: $BRIDGE_NAME"
log_info "Node IP: $NODE1_IP"
log_info "VM: $VM_NAME"
log_info "Image: $IMAGE_PATH"
log_info ""

# Check if image exists
if [ ! -f "$IMAGE_PATH" ]; then
    log_error "Image not found: $IMAGE_PATH"
    log_info "Please run: sudo BUILD_PLATFORM=x64 ./build-zerotouch.sh --node1-only"
    exit 1
fi

# Cleanup any existing VM
if virsh list --all | grep -q "$VM_NAME"; then
    log_info "Cleaning up existing VM..."
    virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
fi

# Cleanup any existing network
if virsh net-list --all | grep -q "$NETWORK_NAME"; then
    log_info "Cleaning up existing network..."
    virsh net-destroy "$NETWORK_NAME" 2>/dev/null || true
    virsh net-undefine "$NETWORK_NAME" 2>/dev/null || true
fi

# Create libvirt network XML (NAT mode like platform project)
log_info "Creating libvirt NAT network..."
NETWORK_XML="/tmp/k8s-zerotouch-network.xml"
cat > "$NETWORK_XML" <<EOF
<network>
  <name>$NETWORK_NAME</name>
  <forward mode='nat'/>
  <bridge name='$BRIDGE_NAME' stp='on' delay='0'/>
  <dns enable='no'/>
  <ip address='$PRIVATE_GATEWAY' netmask='255.255.255.0'/>
</network>
EOF

# Define and start network
sudo virsh net-define "$NETWORK_XML"
sudo virsh net-start "$NETWORK_NAME"
sudo virsh net-autostart "$NETWORK_NAME"

log_success "Network created: $NETWORK_NAME"

# Enable IP forwarding (if not already enabled)
if ! sysctl net.ipv4.ip_forward | grep -q "= 1"; then
    log_info "Enabling IP forwarding..."
    sudo sysctl -w net.ipv4.ip_forward=1
fi

# Add NAT rule for internet access
log_info "Configuring NAT..."
sudo iptables -t nat -C POSTROUTING -s $PRIVATE_SUBNET ! -d $PRIVATE_SUBNET -j MASQUERADE 2>/dev/null || \
    sudo iptables -t nat -A POSTROUTING -s $PRIVATE_SUBNET ! -d $PRIVATE_SUBNET -j MASQUERADE

log_success "NAT configured"

# Copy image to libvirt directory
LIBVIRT_IMAGE="/var/lib/libvirt/images/${VM_NAME}.img"
log_info "Copying image to libvirt directory..."
sudo cp "$IMAGE_PATH" "$LIBVIRT_IMAGE"
sudo chmod 644 "$LIBVIRT_IMAGE"

log_success "Image copied to $LIBVIRT_IMAGE"

# Create VM with virt-install (like platform project)
log_info "Creating VM with virt-install..."
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

VIRT_INSTALL_PID=$!
log_info "virt-install started (PID: $VIRT_INSTALL_PID)"

# Wait for VM to start
log_info "Waiting for VM to start..."
sleep 10

# Wait for VM to be running
MAX_WAIT=60
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
    if virsh list | grep -q "$VM_NAME.*running"; then
        log_success "VM is running"
        break
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    log_error "VM did not start within ${MAX_WAIT}s"
    exit 1
fi

# Wait for SSH to become available
log_info ""
log_info "Waiting for SSH to become available on $NODE1_IP..."
MAX_BOOT_WAIT=120
BOOT_START=$(date +%s)

while true; do
    if ssh -i "$SSH_KEY" \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=2 \
           -o BatchMode=yes \
           k8sadmin@$NODE1_IP "echo 'SSH Ready'" &>/dev/null; then
        BOOT_TIME=$(($(date +%s) - BOOT_START))
        log_success "SSH available after ${BOOT_TIME}s"
        break
    fi

    ELAPSED=$(($(date +%s) - BOOT_START))
    if [ $ELAPSED -gt $MAX_BOOT_WAIT ]; then
        log_error "SSH did not become available within ${MAX_BOOT_WAIT}s"
        log_info "Check VM console: sudo virsh console $VM_NAME"
        exit 1
    fi

    echo -n "."
    sleep 5
done

# Verify network configuration
log_info ""
log_info "=========================================="
log_info "Verifying Network Configuration"
log_info "=========================================="

log_info "Hostname:"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    k8sadmin@$NODE1_IP "hostname"

log_info ""
log_info "IP addresses:"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    k8sadmin@$NODE1_IP "ip addr show | grep 'inet.*192.168'"

log_info ""
log_info "Internet connectivity:"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    k8sadmin@$NODE1_IP "ping -c 3 8.8.8.8"

log_success ""
log_success "Network configuration verified!"

# Monitor bootstrap
log_info ""
log_info "=========================================="
log_info "Monitoring Bootstrap Progress"
log_info "=========================================="
log_info "This will take approximately 18 minutes..."
log_info ""

# Tail bootstrap log
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    k8sadmin@$NODE1_IP "tail -f /var/log/bootstrap.log 2>/dev/null || tail -f /var/log/cloud-init-output.log" &
TAIL_PID=$!

# Wait for bootstrap completion
log_info "(Press Ctrl-C to stop monitoring)"
log_info ""

# Function to check completion
check_completion() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        k8sadmin@$NODE1_IP "grep -q 'Bootstrap complete' /var/log/bootstrap.log 2>/dev/null"
}

# Monitor until complete or timeout (30 minutes)
START_TIME=$(date +%s)
MAX_TIME=1800

while true; do
    sleep 30

    if check_completion; then
        TOTAL_TIME=$(($(date +%s) - START_TIME))
        log_success ""
        log_success "=========================================="
        log_success "Bootstrap completed in ${TOTAL_TIME}s!"
        log_success "=========================================="
        kill $TAIL_PID 2>/dev/null || true
        break
    fi

    ELAPSED=$(($(date +%s) - START_TIME))
    if [ $ELAPSED -gt $MAX_TIME ]; then
        log_error "Bootstrap did not complete within ${MAX_TIME}s"
        kill $TAIL_PID 2>/dev/null || true
        break
    fi
done

# Show cluster status
log_info ""
log_info "Kubernetes Cluster Status:"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    k8sadmin@$NODE1_IP "sudo kubectl get nodes -o wide" || true

log_info ""
log_info "All Pods:"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    k8sadmin@$NODE1_IP "sudo kubectl get pods -A" || true

log_success ""
log_success "=========================================="
log_success "Test Complete!"
log_success "=========================================="
log_info "VM Name: $VM_NAME"
log_info "VM IP: $NODE1_IP"
log_info "SSH: ssh -i $SSH_KEY k8sadmin@$NODE1_IP"
log_info ""
log_info "To view console: sudo virsh console $VM_NAME"
log_info "To stop VM: sudo virsh destroy $VM_NAME"
log_info "To remove VM: sudo virsh undefine $VM_NAME --remove-all-storage"
log_info "To remove network: sudo virsh net-destroy $NETWORK_NAME && sudo virsh net-undefine $NETWORK_NAME"
log_info ""
