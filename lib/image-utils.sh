#!/bin/bash
################################################################################
# Image Manipulation Utilities
#
# Functions for mounting, modifying, and unmounting disk images
# for zero-touch deployment customization.
################################################################################

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging
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

log_debug() {
    [ "${DEBUG:-false}" = "true" ] && echo -e "${BLUE}[DEBUG]${NC} $1"
}

################################################################################
# Global variables for cleanup
################################################################################

LOOP_DEVICE=""
MOUNT_POINT=""

################################################################################
# Cleanup function
################################################################################

cleanup_image() {
    local exit_code=$?

    if [ -n "$MOUNT_POINT" ] && mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log_info "Unmounting $MOUNT_POINT"
        umount -f "$MOUNT_POINT" 2>/dev/null || true
        sleep 1
    fi

    if [ -n "$LOOP_DEVICE" ] && [ -e "$LOOP_DEVICE" ]; then
        log_info "Detaching loop device $LOOP_DEVICE"
        losetup -d "$LOOP_DEVICE" 2>/dev/null || true
        sleep 1
    fi

    if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
        rmdir "$MOUNT_POINT" 2>/dev/null || true
    fi

    LOOP_DEVICE=""
    MOUNT_POINT=""

    return $exit_code
}

# Register cleanup on exit
trap cleanup_image EXIT INT TERM

################################################################################
# Mount image functions
################################################################################

mount_image() {
    local image_path="$1"
    local mount_point="$2"

    log_info "Mounting image: $image_path"
    echo "[DEBUG] Starting mount_image function" >&2

    # Check if image exists
    if [ ! -f "$image_path" ]; then
        log_error "Image not found: $image_path"
        return 1
    fi
    echo "[DEBUG] Image file exists" >&2

    # Create mount point
    mkdir -p "$mount_point"
    MOUNT_POINT="$mount_point"
    echo "[DEBUG] Mount point created: $mount_point" >&2

    # Detect image format
    echo "[DEBUG] Detecting image format..." >&2
    local image_format=$(qemu-img info "$image_path" 2>&1 | grep 'file format:' | awk '{print $3}')
    echo "[DEBUG] Image format: $image_format" >&2

    # Setup loop device
    echo "[DEBUG] About to check image format type..." >&2
    if [ "$image_format" = "qcow2" ]; then
        echo "[DEBUG] Format is qcow2" >&2
        log_info "Mounting qcow2 image via NBD"

        # Load nbd module
        modprobe nbd max_part=8 2>/dev/null || true

        # Find free NBD device
        local nbd_device=""
        for i in {0..15}; do
            if [ ! -e "/sys/block/nbd$i/pid" ]; then
                nbd_device="/dev/nbd$i"
                break
            fi
        done

        if [ -z "$nbd_device" ]; then
            log_error "No free NBD devices available"
            return 1
        fi

        # Connect qcow2 to NBD
        qemu-nbd --connect="$nbd_device" "$image_path"
        sleep 2

        # Find the root partition (usually nbd0p2 or nbd0p1)
        local root_part=""
        if [ -e "${nbd_device}p2" ]; then
            root_part="${nbd_device}p2"
        elif [ -e "${nbd_device}p1" ]; then
            root_part="${nbd_device}p1"
        else
            log_error "Cannot find root partition on $nbd_device"
            qemu-nbd --disconnect "$nbd_device" 2>/dev/null || true
            return 1
        fi

        LOOP_DEVICE="$nbd_device"

        # Mount root partition
        mount "$root_part" "$mount_point"

    else
        # Raw image - use losetup
        echo "[DEBUG] Entering raw image mount path" >&2
        log_info "Mounting raw image via loop device"

        # Setup loop device with partition scan
        echo "[DEBUG] Running losetup..." >&2
        LOOP_DEVICE=$(losetup -f --show -P "$image_path" 2>&1)
        echo "[DEBUG] losetup returned: $LOOP_DEVICE" >&2
        if [ -z "$LOOP_DEVICE" ]; then
            log_error "Failed to create loop device"
            return 1
        fi
        log_info "Loop device: $LOOP_DEVICE"

        # Wait briefly for partition devices to appear
        sleep 0.5

        # Check if partition devices exist
        if [ ! -e "${LOOP_DEVICE}p1" ] && [ ! -e "${LOOP_DEVICE}p2" ]; then
            log_error "No partitions found on $LOOP_DEVICE"
            ls -la ${LOOP_DEVICE}* 2>&1 | tee -a /tmp/loop-debug.log || true
            losetup -d "$LOOP_DEVICE" 2>/dev/null || true
            return 1
        fi

        # Find the root partition (usually ${LOOP_DEVICE}p1 for this image)
        local root_part=""
        if [ -e "${LOOP_DEVICE}p1" ]; then
            root_part="${LOOP_DEVICE}p1"
        elif [ -e "${LOOP_DEVICE}p2" ]; then
            root_part="${LOOP_DEVICE}p2"
        else
            log_error "Cannot find root partition on $LOOP_DEVICE"
            losetup -d "$LOOP_DEVICE" 2>/dev/null || true
            return 1
        fi

        log_info "Root partition: $root_part"

        # Mount root partition
        log_info "Mounting $root_part to $mount_point..."
        if ! mount "$root_part" "$mount_point"; then
            log_error "Failed to mount $root_part"
            losetup -d "$LOOP_DEVICE" 2>/dev/null || true
            return 1
        fi
    fi

    log_info "Image mounted at $mount_point"
    return 0
}

unmount_image() {
    cleanup_image
}

################################################################################
# File injection functions
################################################################################

inject_file() {
    local source_file="$1"
    local dest_path="$2"  # Relative to mount point
    local permissions="${3:-644}"

    if [ ! -d "$MOUNT_POINT" ]; then
        log_error "No image mounted"
        return 1
    fi

    if [ ! -f "$source_file" ]; then
        log_error "Source file not found: $source_file"
        return 1
    fi

    local full_dest="$MOUNT_POINT/$dest_path"
    local dest_dir="$(dirname "$full_dest")"

    log_info "Injecting $source_file -> $dest_path"

    # Create destination directory
    mkdir -p "$dest_dir"

    # Copy file
    cp "$source_file" "$full_dest"

    # Set permissions
    chmod "$permissions" "$full_dest"

    log_info "File injected successfully"
    return 0
}

inject_content() {
    local content="$1"
    local dest_path="$2"  # Relative to mount point
    local permissions="${3:-644}"

    if [ ! -d "$MOUNT_POINT" ]; then
        log_error "No image mounted"
        return 1
    fi

    local full_dest="$MOUNT_POINT/$dest_path"
    local dest_dir="$(dirname "$full_dest")"

    log_info "Injecting content -> $dest_path"

    # Create destination directory
    mkdir -p "$dest_dir"

    # Write content
    echo "$content" > "$full_dest"

    # Set permissions
    chmod "$permissions" "$full_dest"

    log_info "Content injected successfully"
    return 0
}

inject_directory() {
    local source_dir="$1"
    local dest_path="$2"  # Relative to mount point

    if [ ! -d "$MOUNT_POINT" ]; then
        log_error "No image mounted"
        return 1
    fi

    if [ ! -d "$source_dir" ]; then
        log_error "Source directory not found: $source_dir"
        return 1
    fi

    local full_dest="$MOUNT_POINT/$dest_path"

    log_info "Injecting directory $source_dir -> $dest_path"

    # Create destination directory
    mkdir -p "$full_dest"

    # Copy directory contents preserving permissions
    cp -a "$source_dir"/* "$full_dest/" 2>/dev/null || true

    log_info "Directory injected successfully"
    return 0
}

################################################################################
# Template processing
################################################################################

process_template() {
    local template_file="$1"
    local output_file="$2"

    if [ ! -f "$template_file" ]; then
        log_error "Template not found: $template_file"
        return 1
    fi

    log_info "Processing template: $template_file"

    # Simple variable substitution using envsubst
    # Variables should be in format ${VAR_NAME} in template
    envsubst < "$template_file" > "$output_file"

    if [ $? -eq 0 ]; then
        log_info "Template processed successfully"
        return 0
    else
        log_error "Template processing failed"
        return 1
    fi
}

################################################################################
# Image cloning
################################################################################

clone_image() {
    local source_image="$1"
    local dest_image="$2"

    log_info "Cloning image: $source_image -> $dest_image"

    if [ ! -f "$source_image" ]; then
        log_error "Source image not found: $source_image"
        return 1
    fi

    # Create destination directory
    mkdir -p "$(dirname "$dest_image")"

    # Clone image
    cp "$source_image" "$dest_image"

    if [ $? -eq 0 ]; then
        log_info "Image cloned successfully"
        return 0
    else
        log_error "Image cloning failed"
        return 1
    fi
}

################################################################################
# Resize image (if needed)
################################################################################

resize_image() {
    local image_path="$1"
    local new_size="$2"  # e.g., "+10G" or "50G"

    log_info "Resizing image: $image_path to $new_size"

    # Detect format
    local image_format=$(qemu-img info "$image_path" | grep 'file format:' | awk '{print $3}')

    if [ "$image_format" = "qcow2" ]; then
        qemu-img resize "$image_path" "$new_size"
    else
        # Raw image - use truncate
        truncate -s "$new_size" "$image_path"
    fi

    if [ $? -eq 0 ]; then
        log_info "Image resized successfully"
        return 0
    else
        log_error "Image resize failed"
        return 1
    fi
}

################################################################################
# Cloud-init injection (NoCloud datasource)
################################################################################

inject_cloud_init() {
    local user_data_file="$1"
    local meta_data_file="$2"

    if [ ! -d "$MOUNT_POINT" ]; then
        log_error "No image mounted"
        return 1
    fi

    log_info "Injecting cloud-init configuration"

    # Use NoCloud datasource seed location
    # This is the standard location where cloud-init looks for NoCloud data
    local cloud_init_dir="$MOUNT_POINT/var/lib/cloud/seed/nocloud"

    # Create the directory if it doesn't exist
    mkdir -p "$cloud_init_dir"

    log_info "Cloud-init directory: $cloud_init_dir"

    # Copy user-data
    if [ -f "$user_data_file" ]; then
        cp "$user_data_file" "$cloud_init_dir/user-data"
        chmod 600 "$cloud_init_dir/user-data"
        log_info "Injected user-data"
    else
        log_error "user-data file not found: $user_data_file"
        return 1
    fi

    # Copy meta-data
    if [ -f "$meta_data_file" ]; then
        cp "$meta_data_file" "$cloud_init_dir/meta-data"
        chmod 600 "$cloud_init_dir/meta-data"
        log_info "Injected meta-data"
    else
        log_warn "meta-data file not found: $meta_data_file (creating empty)"
        echo "instance-id: $(uuidgen || echo 'iid-local01')" > "$cloud_init_dir/meta-data"
        chmod 600 "$cloud_init_dir/meta-data"
    fi

    log_info "Cloud-init configuration injected successfully"
    return 0
}

################################################################################
# Check if image is mounted
################################################################################

is_mounted() {
    [ -n "$MOUNT_POINT" ] && mountpoint -q "$MOUNT_POINT" 2>/dev/null
}

################################################################################
# Get mount point
################################################################################

get_mount_point() {
    echo "$MOUNT_POINT"
}

################################################################################
# Testing/Validation
################################################################################

validate_image() {
    local image_path="$1"

    log_info "Validating image: $image_path"

    if [ ! -f "$image_path" ]; then
        log_error "Image file not found"
        return 1
    fi

    # Check image format
    if ! qemu-img info "$image_path" >/dev/null 2>&1; then
        log_error "Invalid image format"
        return 1
    fi

    log_info "Image validation passed"
    return 0
}
