#!/bin/bash
################################################################################
# build-all.sh - Unified Build Script for All Platforms
#
# Builds zero-touch Kubernetes images for both x64 and Pi5 platforms.
#
# Usage:
#   ./build-all.sh                    # Build both x64 and pi5 (default)
#   ./build-all.sh --platform=x64     # Build only x64
#   ./build-all.sh --platform=pi5     # Build only pi5
#   ./build-all.sh --platform=all     # Build both (explicit)
#   ./build-all.sh --help             # Show help
#
# Environment:
#   Can be run locally or in GitHub Actions
#
################################################################################

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default platform (all means both x64 and pi5)
BUILD_PLATFORM="all"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --platform=*)
            BUILD_PLATFORM="${1#*=}"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --platform=x64|pi5|all    Platform to build (default: all)"
            echo "  --help, -h                Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                        # Build both x64 and pi5"
            echo "  $0 --platform=x64         # Build only x64"
            echo "  $0 --platform=pi5         # Build only pi5"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate platform argument
if [[ ! "$BUILD_PLATFORM" =~ ^(x64|pi5|all)$ ]]; then
    echo "ERROR: Invalid platform '$BUILD_PLATFORM'"
    echo "Valid options: x64, pi5, all"
    exit 1
fi

################################################################################
# Banner
################################################################################

echo "=========================================="
echo "OSBuild - Unified Build System"
echo "=========================================="
echo "Platform: $BUILD_PLATFORM"
echo "Directory: $SCRIPT_DIR"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
echo ""

################################################################################
# Pre-flight Checks
################################################################################

echo "Running pre-flight checks..."
echo ""

# Check if .env exists
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "⚠️  WARNING: .env file not found"
    echo ""
    echo "For zero-touch deployment, you need to configure .env:"
    echo "  cp .env.sample .env"
    echo "  nano .env"
    echo ""
    echo "Continuing anyway (basic images will be built)..."
    echo ""
fi

# Check for Docker (needed for Pi5 builds)
if [[ "$BUILD_PLATFORM" == "pi5" ]] || [[ "$BUILD_PLATFORM" == "all" ]]; then
    if ! docker info >/dev/null 2>&1; then
        echo "❌ ERROR: Docker is not running (required for Pi5 builds)"
        echo "Please start Docker and try again"
        exit 1
    fi
    echo "✅ Docker is running"
fi

# Check for QEMU/KVM (needed for x64 builds)
if [[ "$BUILD_PLATFORM" == "x64" ]] || [[ "$BUILD_PLATFORM" == "all" ]]; then
    if ! command -v qemu-img &> /dev/null; then
        echo "❌ ERROR: qemu-img not found (required for x64 builds)"
        echo "Install with: sudo apt-get install qemu-utils"
        exit 1
    fi
    echo "✅ QEMU tools available"
fi

echo ""

################################################################################
# Build Function
################################################################################

build_x64() {
    echo "=========================================="
    echo "Building x64 Platform"
    echo "=========================================="
    echo ""

    # Build base x64 image
    echo "Step 1/2: Building base x64 image..."
    cd "$SCRIPT_DIR"
    sudo ./build-x64.sh

    echo ""
    echo "Step 2/2: Building zero-touch x64 images..."
    sudo BUILD_PLATFORM=x64 ./build-zerotouch.sh

    echo ""
    echo "✅ x64 build complete"
    echo ""
}

build_pi5() {
    echo "=========================================="
    echo "Building Pi5 Platform"
    echo "=========================================="
    echo ""

    # Build zero-touch Pi5 images (which internally calls build-pi5.sh)
    echo "Building zero-touch Pi5 images..."
    cd "$SCRIPT_DIR"
    sudo BUILD_PLATFORM=pi5 ./build-zerotouch.sh

    echo ""
    echo "✅ Pi5 build complete"
    echo ""
}

################################################################################
# Build Execution
################################################################################

START_TIME=$(date +%s)

if [[ "$BUILD_PLATFORM" == "all" ]]; then
    echo "Building all platforms (x64 and pi5)..."
    echo ""

    # Build x64 first
    build_x64

    # Build pi5 second
    build_pi5

elif [[ "$BUILD_PLATFORM" == "x64" ]]; then
    build_x64

elif [[ "$BUILD_PLATFORM" == "pi5" ]]; then
    build_pi5
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

################################################################################
# Summary
################################################################################

echo ""
echo "=========================================="
echo "Build Summary"
echo "=========================================="
echo "Platform: $BUILD_PLATFORM"
echo "Duration: ${MINUTES}m ${SECONDS}s"
echo ""

# List outputs
if [[ "$BUILD_PLATFORM" == "x64" ]] || [[ "$BUILD_PLATFORM" == "all" ]]; then
    echo "x64 Outputs:"
    if [ -d "$SCRIPT_DIR/output/x64/zerotouch" ]; then
        ls -lh "$SCRIPT_DIR/output/x64/zerotouch"/*.img 2>/dev/null || echo "  No .img files found"
    else
        echo "  Output directory not found"
    fi
    echo ""
fi

if [[ "$BUILD_PLATFORM" == "pi5" ]] || [[ "$BUILD_PLATFORM" == "all" ]]; then
    echo "Pi5 Outputs:"
    if [ -d "$SCRIPT_DIR/output/pi5/zerotouch" ]; then
        ls -lh "$SCRIPT_DIR/output/pi5/zerotouch"/*.img 2>/dev/null || echo "  No .img files found"
    else
        echo "  Output directory not found"
    fi
    echo ""
fi

echo "=========================================="
echo "✅ All builds completed successfully!"
echo "=========================================="
echo ""

# Deployment hints
if [[ "$BUILD_PLATFORM" == "x64" ]] || [[ "$BUILD_PLATFORM" == "all" ]]; then
    echo "Deploy x64 images:"
    echo "  Use deploy-and-monitor.sh for KVM/libvirt deployment"
    echo ""
fi

if [[ "$BUILD_PLATFORM" == "pi5" ]] || [[ "$BUILD_PLATFORM" == "all" ]]; then
    echo "Deploy Pi5 images:"
    echo "  Flash to SD card:"
    echo "  sudo dd if=output/pi5/zerotouch/<image>.img of=/dev/sdX bs=4M status=progress conv=fsync"
    echo ""
fi

exit 0
