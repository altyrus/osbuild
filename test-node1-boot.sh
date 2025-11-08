#!/bin/bash
################################################################################
# Test Node1 Boot Script
#
# Boots the node1 zero-touch image in KVM for testing
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="$SCRIPT_DIR/output/x64/zerotouch/k8s-node1.img"
CREDENTIALS="$SCRIPT_DIR/output/x64/zerotouch/credentials"

if [ ! -f "$IMAGE" ]; then
    echo "ERROR: Image not found: $IMAGE"
    echo "Please run: sudo BUILD_PLATFORM=x64 ./build-zerotouch.sh --node1-only"
    exit 1
fi

echo "========================================"
echo "Zero-Touch Node1 Test Boot"
echo "========================================"
echo "Image: $IMAGE"
echo "SSH Key: $CREDENTIALS/id_rsa"
echo ""
echo "Starting VM..."
echo "Note: VM will boot and run bootstrap automatically"
echo ""
echo "Monitor bootstrap after ~1 minute:"
echo "  ssh -i $CREDENTIALS/id_rsa k8sadmin@192.168.100.11 tail -f /var/log/bootstrap.log"
echo ""
echo "Access services after ~18 minutes:"
echo "  http://192.168.1.30/"
echo ""
echo "Press Ctrl-A then X to exit QEMU"
echo "========================================"
echo ""

sleep 3

sudo qemu-system-x86_64 \
  -enable-kvm \
  -m 16384 \
  -smp 4 \
  -drive file="$IMAGE",format=raw,if=virtio \
  -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:80,hostfwd=tcp::8443-:443 \
  -device virtio-net-pci,netdev=net0 \
  -serial mon:stdio

echo ""
echo "VM exited"
