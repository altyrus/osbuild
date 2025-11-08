#!/bin/bash
# Run QEMU directly with console output and TAP networking

set -e

IMAGE="output/x64/zerotouch/k8s-node1.img"
TAP_IFACE="tap-zt0"
BRIDGE="virbr-k8s"
MAC="52:54:00:12:34:56"

echo "======================================"
echo "Starting QEMU with Console Output"
echo "======================================"
echo "Image: $IMAGE"
echo "TAP Interface: $TAP_IFACE"
echo "Bridge: $BRIDGE"
echo ""

# Create TAP interface if it doesn't exist
if ! ip link show "$TAP_IFACE" &>/dev/null; then
    echo "Creating TAP interface..."
    sudo ip tuntap add dev "$TAP_IFACE" mode tap user $(whoami)
    sudo ip link set "$TAP_IFACE" up
fi

# Attach to bridge
echo "Attaching TAP to bridge $BRIDGE..."
sudo ip link set "$TAP_IFACE" master "$BRIDGE"
sudo ip link set "$TAP_IFACE" up

echo ""
echo "Starting QEMU (console output below)..."
echo "======================================"
echo ""

# Run QEMU with console output
sudo qemu-system-x86_64 \
  -enable-kvm \
  -m 16384 \
  -smp 4 \
  -drive file="$IMAGE",format=raw,if=virtio \
  -netdev tap,id=net0,ifname="$TAP_IFACE",script=no,downscript=no \
  -device virtio-net-pci,netdev=net0,mac="$MAC" \
  -nographic \
  -serial mon:stdio

# Cleanup on exit
echo ""
echo "QEMU exited. Cleaning up..."
sudo ip link delete "$TAP_IFACE" 2>/dev/null || true
