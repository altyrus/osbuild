#!/bin/bash
################################################################################
# Test freshly rebuilt image with bridge networking
# Verifies static IP configuration (192.168.100.11) applies correctly
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="$SCRIPT_DIR/output/x64/zerotouch/k8s-node1.img"
TAP_IFACE="tap-fresh-test"
BRIDGE="virbr-k8s"
MAC="52:54:00:12:34:58"
NODE_IP="192.168.100.11"
LOG_FILE="/tmp/fresh-bridge-test.log"
CONSOLE_LOG="/tmp/fresh-console.log"

echo "=========================================="
echo "Testing Fresh Image with Bridge Networking"
echo "=========================================="
echo "Image: $IMAGE"
echo "TAP: $TAP_IFACE"
echo "Bridge: $BRIDGE"
echo "Expected IP: $NODE_IP"
echo "Console Log: $CONSOLE_LOG"
echo ""

# Clean up any existing TAP
sudo ip link delete "$TAP_IFACE" 2>/dev/null || true

# Create TAP interface
echo "[1/5] Creating TAP interface..."
sudo ip tuntap add dev "$TAP_IFACE" mode tap user $(whoami)
sudo ip link set "$TAP_IFACE" up
echo "✓ TAP interface created"

# Attach to bridge
echo "[2/5] Attaching TAP to bridge $BRIDGE..."
sudo ip link set "$TAP_IFACE" master "$BRIDGE"
sudo ip link set "$TAP_IFACE" up
echo "✓ TAP attached to bridge"

# Verify bridge connection
echo "[3/5] Verifying bridge setup..."
sudo brctl show "$BRIDGE" | grep "$TAP_IFACE" && echo "✓ TAP is on bridge" || echo "✗ TAP not on bridge"

# Start QEMU in background with console logging
echo "[4/5] Starting QEMU..."
rm -f "$CONSOLE_LOG"

timeout 180 sudo qemu-system-x86_64 \
  -enable-kvm \
  -m 16384 \
  -smp 4 \
  -drive file="$IMAGE",format=raw,if=virtio \
  -netdev tap,id=net0,ifname="$TAP_IFACE",script=no,downscript=no \
  -device virtio-net-pci,netdev=net0,mac="$MAC" \
  -nographic \
  -serial file:"$CONSOLE_LOG" \
  > /tmp/qemu-output.log 2>&1 &

QEMU_PID=$!
echo "✓ QEMU started (PID: $QEMU_PID)"
echo ""

# Wait for boot and monitor
echo "[5/5] Monitoring boot progress..."
echo "Waiting 60 seconds for system to boot and configure network..."

for i in {1..60}; do
    echo -n "."
    sleep 1

    # Check if QEMU is still running
    if ! kill -0 $QEMU_PID 2>/dev/null; then
        echo ""
        echo "✗ QEMU exited early!"
        break
    fi

    # Check for login prompt in console (indicates boot complete)
    if [ -f "$CONSOLE_LOG" ] && grep -q "login:" "$CONSOLE_LOG" 2>/dev/null; then
        echo ""
        echo "✓ Boot complete (login prompt detected)"
        break
    fi
done

echo ""
echo "=========================================="
echo "Network Tests"
echo "=========================================="

# Test 1: Check if IP is visible from host
echo "Test 1: Checking if VM has IP $NODE_IP..."
if sudo arp -n | grep -q "$NODE_IP"; then
    echo "✓ IP $NODE_IP found in ARP table"
else
    echo "⚠ IP $NODE_IP not in ARP table yet"
fi

# Test 2: Ping test
echo ""
echo "Test 2: Pinging $NODE_IP..."
if sudo ping -c 3 -W 2 "$NODE_IP" > /tmp/ping-test.log 2>&1; then
    echo "✓ Ping successful!"
    cat /tmp/ping-test.log | tail -3
else
    echo "✗ Ping failed"
    echo "Ping output:"
    cat /tmp/ping-test.log
fi

# Test 3: SSH port check
echo ""
echo "Test 3: Checking SSH port 22..."
if timeout 5 bash -c "echo > /dev/tcp/$NODE_IP/22" 2>/dev/null; then
    echo "✓ SSH port 22 is open!"
else
    echo "✗ SSH port 22 not accessible"
fi

# Test 4: Try SSH connection
echo ""
echo "Test 4: Attempting SSH connection..."
if timeout 10 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i ~/.ssh/id_rsa admin@$NODE_IP "hostname && ip addr show" > /tmp/ssh-test.log 2>&1; then
    echo "✓ SSH connection successful!"
    echo "---"
    cat /tmp/ssh-test.log
    echo "---"
else
    echo "✗ SSH connection failed"
    echo "SSH output:"
    cat /tmp/ssh-test.log
fi

echo ""
echo "=========================================="
echo "Console Output Analysis"
echo "=========================================="

if [ -f "$CONSOLE_LOG" ]; then
    echo "Checking for key boot markers..."

    if grep -q "cloud-init.*finished" "$CONSOLE_LOG"; then
        echo "✓ Cloud-init completed"
    else
        echo "✗ Cloud-init not finished"
    fi

    if grep -q "192.168.100.11" "$CONSOLE_LOG"; then
        echo "✓ IP 192.168.100.11 detected in console"
    else
        echo "✗ IP not found in console"
    fi

    if grep -q "Bootstrap script started" "$CONSOLE_LOG"; then
        echo "✓ Bootstrap script started"
    else
        echo "✗ Bootstrap not started"
    fi

    if grep -q "Network test.*✓" "$CONSOLE_LOG"; then
        echo "✓ Bootstrap network test passed"
    elif grep -q "Network test.*✗" "$CONSOLE_LOG"; then
        echo "⚠ Bootstrap network test failed (expected with this test setup)"
    fi

    echo ""
    echo "Last 30 lines of console output:"
    echo "---"
    tail -30 "$CONSOLE_LOG"
    echo "---"
else
    echo "✗ Console log not found"
fi

echo ""
echo "=========================================="
echo "Cleanup"
echo "=========================================="

# Kill QEMU
if kill -0 $QEMU_PID 2>/dev/null; then
    echo "Stopping QEMU (PID: $QEMU_PID)..."
    sudo kill -9 $QEMU_PID 2>/dev/null || true
    sleep 2
fi

# Clean up TAP
echo "Removing TAP interface..."
sudo ip link delete "$TAP_IFACE" 2>/dev/null || true

echo ""
echo "=========================================="
echo "Test Complete"
echo "=========================================="
echo "Full console log: $CONSOLE_LOG"
echo "QEMU output: /tmp/qemu-output.log"
echo "=========================================="
