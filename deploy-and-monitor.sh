#!/bin/bash
################################################################################
# Zero-Touch Deployment and Monitoring Script
#
# This script:
# 1. Registers the built image with libvirt/KVM
# 2. Starts the VM (visible in virt-manager)
# 3. Monitors bootstrap and cluster initialization
# 4. Verifies application accessibility at VIP address
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Source configuration
source "$SCRIPT_DIR/../platform/.env"
source "$SCRIPT_DIR/lib/image-utils.sh"

################################################################################
# Configuration
################################################################################

VM_NAME="k8s-node1"
IMAGE_PATH="$SCRIPT_DIR/output-zerotouch-x64/k8s-node1.img"
NETWORK_NAME="k8s-network"
NODE_IP="${PRIVATE_IP_START}"  # Node 1 gets the starting IP
VIP_ADDRESS="$VIP"
SSH_KEY="$SCRIPT_DIR/output-zerotouch-x64/credentials/id_rsa"
SSH_USER="${SSH_USER:-k8sadmin}"  # Default to k8sadmin if not set

# Monitoring timeouts (in seconds)
SSH_TIMEOUT=300
BOOTSTRAP_TIMEOUT=600
CLUSTER_TIMEOUT=900
SERVICES_TIMEOUT=1200

LOG_FILE="/tmp/deploy-monitor-$(date +%Y%m%d-%H%M%S).log"

################################################################################
# Functions
################################################################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log_section() {
    echo "" | tee -a "$LOG_FILE"
    echo "==========================================================================" | tee -a "$LOG_FILE"
    echo "$*" | tee -a "$LOG_FILE"
    echo "==========================================================================" | tee -a "$LOG_FILE"
}

wait_for_ssh() {
    local ip="$1"
    local timeout="$2"
    local elapsed=0

    log "Waiting for SSH on $ip (timeout: ${timeout}s)..."

    while [ $elapsed -lt $timeout ]; do
        if timeout 5 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 -i "$SSH_KEY" "${SSH_USER}@${ip}" "echo 'SSH ready'" &>/dev/null; then
            log "✓ SSH is ready on $ip"
            return 0
        fi
        echo -n "."
        sleep 5
        elapsed=$((elapsed + 5))
    done

    log "✗ SSH timeout after ${timeout}s"
    return 1
}

ssh_exec() {
    local ip="$1"
    shift
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i "$SSH_KEY" "${SSH_USER}@${ip}" "$@"
}

monitor_bootstrap() {
    local ip="$1"
    local timeout="$2"
    local elapsed=0

    log "Monitoring bootstrap progress..."

    while [ $elapsed -lt $timeout ]; do
        # Check if bootstrap log exists and is growing
        if ssh_exec "$ip" "test -f /var/log/bootstrap.log" 2>/dev/null; then
            local last_line=$(ssh_exec "$ip" "tail -1 /var/log/bootstrap.log" 2>/dev/null || echo "")

            if echo "$last_line" | grep -q "BOOTSTRAP COMPLETE"; then
                log "✓ Bootstrap completed successfully"
                log "  Last line: $last_line"
                return 0
            fi

            if echo "$last_line" | grep -qi "error\|failed\|fatal"; then
                log "⚠ Potential error detected in bootstrap:"
                log "  $last_line"
            fi

            # Show progress every 30 seconds
            if [ $((elapsed % 30)) -eq 0 ]; then
                log "  Bootstrap progress: $last_line"
            fi
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    log "⚠ Bootstrap monitoring timeout after ${timeout}s"
    log "  Fetching last 20 lines of bootstrap log:"
    ssh_exec "$ip" "tail -20 /var/log/bootstrap.log" 2>/dev/null || log "  (Could not retrieve log)"
    return 1
}

check_cluster_ready() {
    local ip="$1"
    local timeout="$2"
    local elapsed=0

    log "Checking Kubernetes cluster status..."

    while [ $elapsed -lt $timeout ]; do
        # Check if kubectl is configured
        if ssh_exec "$ip" "sudo kubectl get nodes 2>/dev/null" | grep -q "Ready"; then
            log "✓ Kubernetes cluster is ready"
            ssh_exec "$ip" "sudo kubectl get nodes" | while read line; do
                log "  $line"
            done
            return 0
        fi

        if [ $((elapsed % 30)) -eq 0 ]; then
            log "  Waiting for cluster... (${elapsed}s / ${timeout}s)"
        fi

        sleep 10
        elapsed=$((elapsed + 10))
    done

    log "✗ Cluster ready timeout after ${timeout}s"
    return 1
}

check_services() {
    local ip="$1"
    local timeout="$2"
    local elapsed=0

    log "Checking service deployments..."

    # Services to check based on .env configuration
    local services=()
    [ "$DEPLOY_PORTAINER" = "true" ] && services+=("portainer")
    [ "$DEPLOY_GRAFANA" = "true" ] && services+=("grafana")
    [ "$DEPLOY_PROMETHEUS" = "true" ] && services+=("prometheus")
    [ "$DEPLOY_LONGHORN" = "true" ] && services+=("longhorn")

    log "  Expecting services: ${services[*]}"

    while [ $elapsed -lt $timeout ]; do
        local all_ready=true

        # Check pods in all namespaces
        local running_pods=$(ssh_exec "$ip" "sudo kubectl get pods -A --no-headers 2>/dev/null | grep Running | wc -l" || echo "0")
        local total_pods=$(ssh_exec "$ip" "sudo kubectl get pods -A --no-headers 2>/dev/null | wc -l" || echo "0")

        if [ "$total_pods" -gt 0 ]; then
            log "  Pods running: $running_pods / $total_pods"

            # Check if all expected services have pods
            for svc in "${services[@]}"; do
                if ! ssh_exec "$ip" "sudo kubectl get pods -A 2>/dev/null | grep -q $svc"; then
                    all_ready=false
                    log "  Waiting for $svc..."
                    break
                fi
            done

            if [ "$all_ready" = true ] && [ "$running_pods" -eq "$total_pods" ]; then
                log "✓ All services deployed and running"
                return 0
            fi
        else
            if [ $((elapsed % 60)) -eq 0 ]; then
                log "  Waiting for pods to be created... (${elapsed}s / ${timeout}s)"
            fi
        fi

        sleep 15
        elapsed=$((elapsed + 15))
    done

    log "⚠ Services check timeout after ${timeout}s"
    log "  Current pod status:"
    ssh_exec "$ip" "sudo kubectl get pods -A" | while read line; do
        log "    $line"
    done
    return 1
}

check_vip_access() {
    local vip="$1"

    log "Checking VIP accessibility at $vip..."

    # Ping test
    if ping -c 3 -W 2 "$vip" &>/dev/null; then
        log "✓ VIP $vip is pingable"
    else
        log "✗ VIP $vip is not pingable"
        return 1
    fi

    # HTTP test on common ports
    for port in 80 443; do
        if timeout 5 bash -c "echo > /dev/tcp/$vip/$port" 2>/dev/null; then
            log "✓ VIP $vip:$port is accessible"
        else
            log "⚠ VIP $vip:$port is not responding"
        fi
    done

    return 0
}

################################################################################
# Main Script
################################################################################

log_section "Zero-Touch Deployment and Monitoring"
log "Log file: $LOG_FILE"
log "Image: $IMAGE_PATH"
log "VM Name: $VM_NAME"
log "Network: $NETWORK_NAME"
log "Node IP: $NODE_IP"
log "VIP Address: $VIP_ADDRESS"

# Verify image exists
if [ ! -f "$IMAGE_PATH" ]; then
    log "✗ Image not found: $IMAGE_PATH"
    log "Please run customize-images.sh first"
    exit 1
fi

log "✓ Image found: $IMAGE_PATH ($(du -h "$IMAGE_PATH" | cut -f1))"

# Check if SSH key exists
if [ ! -f "$SSH_KEY" ]; then
    log "✗ SSH key not found: $SSH_KEY"
    exit 1
fi

log "✓ SSH key found: $SSH_KEY"

# Step 1: Clean up any existing VM
log_section "Step 1: Cleanup"

if virsh list --all | grep -q "$VM_NAME"; then
    log "Removing existing VM: $VM_NAME"
    virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
fi

# Step 2: Create VM storage
log_section "Step 2: Prepare VM Storage"

STORAGE_POOL="default"
STORAGE_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"

log "Converting image to qcow2 format..."
sudo qemu-img convert -f raw -O qcow2 "$IMAGE_PATH" "$STORAGE_PATH"
sudo chown libvirt-qemu:kvm "$STORAGE_PATH"
log "✓ Storage prepared: $STORAGE_PATH"

# Step 3: Define VM with libvirt
log_section "Step 3: Define VM with libvirt"

# Get network bridge name
BRIDGE=$(virsh net-info "$NETWORK_NAME" | grep Bridge | awk '{print $2}')
log "Network bridge: $BRIDGE"

# Create VM definition
cat > "/tmp/${VM_NAME}.xml" <<EOF
<domain type='kvm'>
  <name>${VM_NAME}</name>
  <memory unit='KiB'>16777216</memory>
  <currentMemory unit='KiB'>16777216</currentMemory>
  <vcpu placement='static'>4</vcpu>
  <os>
    <type arch='x86_64'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <vmport state='off'/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='on'/>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${STORAGE_PATH}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'>
      <source network='br0-network'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <input type='tablet' bus='usb'>
    </input>
    <input type='mouse' bus='ps2'/>
    <input type='keyboard' bus='ps2'/>
    <graphics type='spice' autoport='yes'>
      <listen type='address'/>
      <image compression='off'/>
    </graphics>
    <video>
      <model type='qxl' ram='65536' vram='65536' vgamem='16384' heads='1' primary='yes'/>
    </video>
    <memballoon model='virtio'>
    </memballoon>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>
  </devices>
</domain>
EOF

log "Defining VM with libvirt..."
sudo virsh define "/tmp/${VM_NAME}.xml"
log "✓ VM defined: $VM_NAME"
log "  (VM is now visible in virt-manager)"

# Step 4: Start VM
log_section "Step 4: Start VM"

sudo virsh start "$VM_NAME"
log "✓ VM started: $VM_NAME"

sleep 5

# Verify VM is running
if virsh list | grep -q "$VM_NAME.*running"; then
    log "✓ VM is running"
else
    log "✗ VM failed to start"
    exit 1
fi

# Step 5: Wait for SSH
log_section "Step 5: Wait for SSH"

if ! wait_for_ssh "$NODE_IP" "$SSH_TIMEOUT"; then
    log "✗ SSH not available after timeout"
    log "Checking VM status..."
    virsh domstate "$VM_NAME"
    exit 1
fi

# Step 6: Monitor Bootstrap
log_section "Step 6: Monitor Bootstrap Process"

if ! monitor_bootstrap "$NODE_IP" "$BOOTSTRAP_TIMEOUT"; then
    log "⚠ Bootstrap monitoring ended with warnings"
    log "Continuing to cluster checks..."
fi

# Step 7: Check Cluster Status
log_section "Step 7: Verify Kubernetes Cluster"

if ! check_cluster_ready "$NODE_IP" "$CLUSTER_TIMEOUT"; then
    log "✗ Cluster not ready after timeout"
    log "Fetching cluster diagnostics..."
    ssh_exec "$NODE_IP" "sudo kubectl get nodes -o wide" || true
    ssh_exec "$NODE_IP" "sudo kubectl get pods -A" || true
    exit 1
fi

# Step 8: Check Services
log_section "Step 8: Verify Service Deployments"

if ! check_services "$NODE_IP" "$SERVICES_TIMEOUT"; then
    log "⚠ Some services may not be fully ready"
    log "Continuing to VIP checks..."
fi

# Step 9: Check VIP Access
log_section "Step 9: Verify VIP Accessibility"

sleep 30  # Give MetalLB time to configure VIP

if ! check_vip_access "$VIP_ADDRESS"; then
    log "⚠ VIP accessibility check had issues"
    log "MetalLB may still be configuring or services not yet exposed"
fi

# Step 10: Final Status
log_section "Deployment Summary"

log "VM Information:"
log "  Name: $VM_NAME"
log "  Status: $(virsh domstate "$VM_NAME")"
log "  IP Address: $NODE_IP"
log "  VIP Address: $VIP_ADDRESS"

log ""
log "Access Information:"
log "  SSH: ssh -i $SSH_KEY ${SSH_USER}@${NODE_IP}"
log "  Virt-Manager: VM is visible as '$VM_NAME'"

log ""
log "Cluster Status:"
ssh_exec "$NODE_IP" "sudo kubectl get nodes" | while read line; do
    log "  $line"
done

log ""
log "Service Endpoints (if configured):"
log "  VIP: http://${VIP_ADDRESS}"
[ "$DEPLOY_PORTAINER" = "true" ] && log "  Portainer: http://${VIP_ADDRESS}:30777"
[ "$DEPLOY_GRAFANA" = "true" ] && log "  Grafana: http://${VIP_ADDRESS}:30300"

log ""
log_section "Deployment Complete!"
log "Full log saved to: $LOG_FILE"

exit 0
