#!/bin/bash
################################################################################
# Automated Node1 Test Script
#
# Boots node1 image and monitors autonomous deployment progress
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="$SCRIPT_DIR/output/x64/zerotouch/k8s-node1.img"
CREDENTIALS="$SCRIPT_DIR/output/x64/zerotouch/credentials/id_rsa"
SSH_PORT=2222
SSH_USER="k8sadmin"
SSH_HOST="localhost"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Cleanup function
cleanup() {
    log_info "Cleaning up..."
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        log_info "Stopping QEMU (PID: $QEMU_PID)"
        kill "$QEMU_PID" 2>/dev/null || true
        sleep 2
        kill -9 "$QEMU_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

# Check prerequisites
if [ ! -f "$IMAGE" ]; then
    log_error "Image not found: $IMAGE"
    exit 1
fi

if [ ! -f "$CREDENTIALS" ]; then
    log_error "SSH key not found: $CREDENTIALS"
    exit 1
fi

log_info "========================================"
log_info "Zero-Touch Node1 Automated Test"
log_info "========================================"
log_info "Image: $IMAGE"
log_info "SSH: $SSH_USER@$SSH_HOST:$SSH_PORT"
log_info ""

# Start QEMU in background
log_info "Starting QEMU VM..."
sudo qemu-system-x86_64 \
  -enable-kvm \
  -m 16384 \
  -smp 4 \
  -drive file="$IMAGE",format=raw,if=virtio \
  -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22 \
  -device virtio-net-pci,netdev=net0 \
  -nographic \
  -serial file:/tmp/node1-serial.log \
  > /tmp/node1-qemu.log 2>&1 &

QEMU_PID=$!
log_info "QEMU started (PID: $QEMU_PID)"
log_info "Serial output: /tmp/node1-serial.log"
log_info "QEMU output: /tmp/node1-qemu.log"

# Wait for SSH to become available
log_info ""
log_info "Waiting for SSH to become available..."
MAX_BOOT_WAIT=300  # 5 minutes
BOOT_START=$(date +%s)

while true; do
    if ssh -i "$CREDENTIALS" \
           -p $SSH_PORT \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=2 \
           -o BatchMode=yes \
           "$SSH_USER@$SSH_HOST" "echo 'SSH Ready'" &>/dev/null; then
        BOOT_TIME=$(($(date +%s) - BOOT_START))
        log_success "SSH available after ${BOOT_TIME}s"
        break
    fi

    ELAPSED=$(($(date +%s) - BOOT_START))
    if [ $ELAPSED -gt $MAX_BOOT_WAIT ]; then
        log_error "SSH did not become available within ${MAX_BOOT_WAIT}s"
        log_info "Check serial log: /tmp/node1-serial.log"
        exit 1
    fi

    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        log_error "QEMU process died unexpectedly"
        exit 1
    fi

    echo -n "."
    sleep 5
done

# Wait a bit for bootstrap to start
log_info ""
log_info "Waiting for bootstrap script to start..."
sleep 10

# Check if bootstrap log exists
log_info "Checking for bootstrap log..."
if ssh -i "$CREDENTIALS" \
       -p $SSH_PORT \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       "$SSH_USER@$SSH_HOST" "test -f /var/log/bootstrap.log"; then
    log_success "Bootstrap log found"
else
    log_warn "Bootstrap log not found yet, waiting..."
    sleep 30
fi

# Monitor bootstrap progress
log_info ""
log_info "========================================"
log_info "Monitoring Bootstrap Progress"
log_info "========================================"
log_info "This will take approximately 18 minutes..."
log_info ""

# Tail the bootstrap log with timeout
MONITOR_START=$(date +%s)
MAX_DEPLOY_TIME=1800  # 30 minutes max

ssh -i "$CREDENTIALS" \
    -p $SSH_PORT \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "$SSH_USER@$SSH_HOST" \
    "tail -f /var/log/bootstrap.log 2>/dev/null || tail -f /var/log/cloud-init-output.log" &

TAIL_PID=$!

# Wait for completion or timeout
while true; do
    sleep 10

    # Check if bootstrap completed
    if ssh -i "$CREDENTIALS" \
           -p $SSH_PORT \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           "$SSH_USER@$SSH_HOST" \
           "grep -q 'Bootstrap complete' /var/log/bootstrap.log 2>/dev/null"; then
        DEPLOY_TIME=$(($(date +%s) - MONITOR_START))
        log_success ""
        log_success "========================================"
        log_success "Bootstrap completed in ${DEPLOY_TIME}s!"
        log_success "========================================"
        kill $TAIL_PID 2>/dev/null || true
        break
    fi

    # Check for errors
    if ssh -i "$CREDENTIALS" \
           -p $SSH_PORT \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           "$SSH_USER@$SSH_HOST" \
           "grep -q 'FATAL\\|CRITICAL' /var/log/bootstrap.log 2>/dev/null"; then
        log_error ""
        log_error "Bootstrap encountered errors!"
        kill $TAIL_PID 2>/dev/null || true

        log_info ""
        log_info "Last 50 lines of bootstrap log:"
        ssh -i "$CREDENTIALS" \
            -p $SSH_PORT \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            "$SSH_USER@$SSH_HOST" \
            "tail -50 /var/log/bootstrap.log"
        exit 1
    fi

    ELAPSED=$(($(date +%s) - MONITOR_START))
    if [ $ELAPSED -gt $MAX_DEPLOY_TIME ]; then
        log_error "Bootstrap did not complete within ${MAX_DEPLOY_TIME}s"
        kill $TAIL_PID 2>/dev/null || true
        exit 1
    fi

    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        log_error "QEMU process died during bootstrap"
        kill $TAIL_PID 2>/dev/null || true
        exit 1
    fi
done

# Verify cluster status
log_info ""
log_info "Verifying cluster status..."

ssh -i "$CREDENTIALS" \
    -p $SSH_PORT \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "$SSH_USER@$SSH_HOST" \
    "sudo kubectl get nodes -o wide"

log_info ""
log_info "Verifying all pods..."
ssh -i "$CREDENTIALS" \
    -p $SSH_PORT \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "$SSH_USER@$SSH_HOST" \
    "sudo kubectl get pods -A"

log_success ""
log_success "========================================"
log_success "Zero-Touch Deployment Test PASSED!"
log_success "========================================"
log_success "VM is still running for manual inspection"
log_success "SSH: ssh -i $CREDENTIALS -p $SSH_PORT $SSH_USER@$SSH_HOST"
log_success "Press Ctrl-C to stop and cleanup"
log_success ""

# Keep VM running for manual inspection
wait $QEMU_PID
