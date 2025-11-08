#!/bin/bash
################################################################################
# Zero-Touch Kubernetes Image Build Script
#
# Builds fully autonomous Kubernetes cluster images for x64 and Pi5 platforms.
#
# Usage:
#   sudo BUILD_PLATFORM=x64 ./build-zerotouch.sh [--node1-only]
#   sudo BUILD_PLATFORM=pi5 ./build-zerotouch.sh [--node1-only]
#
# Options:
#   --node1-only    Build only node1 image (for testing)
################################################################################

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse options
NODE1_ONLY=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --node1-only)
            NODE1_ONLY=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--node1-only]"
            exit 1
            ;;
    esac
done

# Source utilities first (needed for logging)
source "$SCRIPT_DIR/lib/credential-gen.sh"

# Source configuration
export BUILD_PLATFORM="${BUILD_PLATFORM:-x64}"
source "$SCRIPT_DIR/config/zerotouch-config.env"

################################################################################
# Banner
################################################################################

echo "=========================================="
echo "Zero-Touch Kubernetes Image Builder"
echo "=========================================="
echo "Platform: $BUILD_PLATFORM"
echo "Architecture: $ARCH"
echo "Cluster Name: $CLUSTER_NAME"
echo "Node Count: $([ "$NODE1_ONLY" = true ] && echo "1 (node1 only)" || echo "$NODE_COUNT")"
echo "VIP: $VIP"
echo "Output: $OUTPUT_DIR"
echo "=========================================="
echo ""

# Override node count if node1-only
if [ "$NODE1_ONLY" = true ]; then
    export NODE_COUNT=1
    log_info "Building node1 only (testing mode)"
fi

################################################################################
# STEP 1: Build or verify base image
################################################################################

echo "Step 1: Checking for base image..."

if [ ! -f "$BASE_IMAGE" ]; then
    echo "Base image not found: $BASE_IMAGE"
    echo ""

    # Check if a base build is already running
    if [ "$BUILD_PLATFORM" = "x64" ] && [ -f "/tmp/osbuild-x64.lock" ]; then
        LOCK_PID=$(cat /tmp/osbuild-x64.lock 2>/dev/null || echo "")
        if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
            echo "ERROR: x64 base image build is already running (PID: $LOCK_PID)"
            echo "Please wait for it to complete, then re-run this script."
            exit 1
        fi
    elif [ "$BUILD_PLATFORM" = "pi5" ] && [ -f "/tmp/osbuild-pi5.lock" ]; then
        LOCK_PID=$(cat /tmp/osbuild-pi5.lock 2>/dev/null || echo "")
        if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
            echo "ERROR: Pi5 base image build is already running (PID: $LOCK_PID)"
            echo "Please wait for it to complete, then re-run this script."
            exit 1
        fi
    fi

    echo "Building base image with OSBuild..."

    if [ "$BUILD_PLATFORM" = "x64" ]; then
        echo "Running: $SCRIPT_DIR/build-x64.sh"
        cd "$SCRIPT_DIR"
        ./build-x64.sh

        # Find the latest built image
        LATEST_IMAGE=$(ls -t "$SCRIPT_DIR/output/x64"/k8s-x64-*.img 2>/dev/null | head -1)
        if [ -z "$LATEST_IMAGE" ]; then
            echo "ERROR: x64 image build failed - no output found"
            exit 1
        fi

        # Create symlink for easier reference
        ln -sf "$(basename "$LATEST_IMAGE")" "$SCRIPT_DIR/output/x64/k8s-x64-latest.img"
        BASE_IMAGE="$SCRIPT_DIR/output/x64/k8s-x64-latest.img"

    elif [ "$BUILD_PLATFORM" = "pi5" ]; then
        echo "Running: $SCRIPT_DIR/build-pi5.sh"
        cd "$SCRIPT_DIR"
        ./build-pi5.sh

        # Find the latest built image
        LATEST_IMAGE=$(ls -t "$SCRIPT_DIR/output/pi5"/rpi5-k8s-*.img 2>/dev/null | head -1)
        if [ -z "$LATEST_IMAGE" ]; then
            echo "ERROR: Pi5 image build failed - no output found"
            exit 1
        fi

        # Create symlink
        ln -sf "$(basename "$LATEST_IMAGE")" "$SCRIPT_DIR/output/pi5/rpi5-k8s-latest.img"
        BASE_IMAGE="$SCRIPT_DIR/output/pi5/rpi5-k8s-latest.img"
    fi

    echo "Base image built: $BASE_IMAGE"
else
    echo "Base image found: $BASE_IMAGE"
fi

echo ""

################################################################################
# STEP 2: Generate credentials
################################################################################

echo "Step 2: Generating credentials..."

if [ -f "$CREDENTIALS_DIR/cluster-info.txt" ] && [ -f "$SSH_KEY_PATH" ]; then
    echo "Credentials already exist, skipping generation"
else
    generate_all_credentials "$CREDENTIALS_DIR"
fi

echo ""

################################################################################
# STEP 3: Customize images
################################################################################

echo "Step 3: Customizing images..."

cd "$SCRIPT_DIR"
"$SCRIPT_DIR/customize-images.sh"

echo ""

################################################################################
# STEP 4: Summary
################################################################################

echo "=========================================="
echo "BUILD COMPLETE!"
echo "=========================================="
echo ""
echo "Output images:"
for node_num in $(seq 1 $NODE_COUNT); do
    img_file="$OUTPUT_DIR/${CLUSTER_NAME}-node${node_num}.img"
    if [ -f "$img_file" ]; then
        img_size=$(du -h "$img_file" | cut -f1)
        echo "  Node $node_num: $img_file ($img_size)"
    fi
done
echo ""
echo "Credentials: $CREDENTIALS_DIR/"
echo "  SSH Key: $SSH_KEY_PATH"
echo "  Cluster Info: $CREDENTIALS_DIR/cluster-info.txt"
echo ""
echo "=========================================="
echo "NEXT STEPS"
echo "=========================================="
echo ""

if [ "$BUILD_PLATFORM" = "x64" ]; then
    echo "To test node1 in KVM:"
    echo ""
    echo "  # Start VM"
    echo "  sudo qemu-system-x86_64 \\"
    echo "    -enable-kvm \\"
    echo "    -m 16384 \\"
    echo "    -smp 4 \\"
    echo "    -drive file=$OUTPUT_DIR/${CLUSTER_NAME}-node1.img,format=raw,if=virtio \\"
    echo "    -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:80 \\"
    echo "    -device virtio-net-pci,netdev=net0 \\"
    echo "    -serial mon:stdio"
    echo ""
    echo "  # Or use bridge networking for VIP access:"
    echo "  sudo qemu-system-x86_64 \\"
    echo "    -enable-kvm \\"
    echo "    -m 16384 \\"
    echo "    -smp 4 \\"
    echo "    -drive file=$OUTPUT_DIR/${CLUSTER_NAME}-node1.img,format=raw,if=virtio \\"
    echo "    -netdev bridge,id=net0,br=virbr0 \\"
    echo "    -device virtio-net-pci,netdev=net0 \\"
    echo "    -serial mon:stdio"
    echo ""
    echo "  # Monitor bootstrap (after VM boots):"
    echo "  ssh -i $SSH_KEY_PATH ${SSH_USER}@${NODE1_PRIVATE_IP} tail -f /var/log/bootstrap.log"
    echo ""
    echo "  # Or if using port forwarding:"
    echo "  ssh -i $SSH_KEY_PATH -p 2222 ${SSH_USER}@localhost tail -f /var/log/bootstrap.log"

elif [ "$BUILD_PLATFORM" = "pi5" ]; then
    echo "To flash to SD card:"
    echo ""
    echo "  # Find your SD card device"
    echo "  lsblk"
    echo ""
    echo "  # Flash image (REPLACE /dev/sdX with your SD card!)"
    echo "  sudo dd if=$OUTPUT_DIR/${CLUSTER_NAME}-node1.img \\"
    echo "    of=/dev/sdX \\"
    echo "    bs=4M \\"
    echo "    status=progress \\"
    echo "    conv=fsync"
    echo ""
    echo "  # Insert SD card into Pi5 and power on"
    echo "  # Monitor bootstrap:"
    echo "  ssh -i $SSH_KEY_PATH ${SSH_USER}@${NODE1_PRIVATE_IP} tail -f /var/log/bootstrap.log"
fi

echo ""
echo "Access services (after ~15-20 minutes):"
echo "  Welcome Page: http://${VIP}/"
echo "  Portainer: http://${VIP}/portainer/"
echo "  Grafana: http://${VIP}/grafana/ (admin/${GRAFANA_ADMIN_PASSWORD})"
echo "  Prometheus: http://${VIP}/prometheus/"
echo "  Longhorn: http://${VIP}/longhorn/"
echo "  MinIO: http://${VIP}/minio/ (see $CREDENTIALS_DIR/minio-password.txt)"
echo ""
echo "=========================================="

exit 0
