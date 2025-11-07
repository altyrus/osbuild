#!/bin/bash
################################################################################
# Zero-Touch Image Customization Script
#
# Customizes base OSBuild images with node-specific configuration,
# bootstrap scripts, and cloud-init for zero-touch deployment.
################################################################################

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utilities
source "$SCRIPT_DIR/lib/image-utils.sh"
source "$SCRIPT_DIR/config/zerotouch-config.env"

################################################################################
# Functions
################################################################################

customize_node_image() {
    local node_num="$1"
    local base_image="$2"
    local output_image="$3"

    log_info "=========================================="
    log_info "Customizing Node $node_num Image"
    log_info "=========================================="

    # Get node-specific configuration
    local node_hostname=$(get_node_hostname $node_num)
    local node_private_ip=$(get_node_private_ip $node_num)
    local node_external_ip=$(get_node_external_ip $node_num)

    log_info "Node: $node_hostname"
    log_info "Private IP: $node_private_ip"
    log_info "External IP: $node_external_ip"

    # Clone base image
    log_info "Cloning base image..."
    clone_image "$base_image" "$output_image"

    # Mount image
    local mount_point="${BUILD_WORK_DIR}/mnt-node${node_num}"
    mount_image "$output_image" "$mount_point"

    log_info "Image mounted at: $mount_point"

    # Create bootstrap directory structure
    log_info "Creating bootstrap directory structure..."
    mkdir -p "$mount_point/opt/bootstrap/lib"
    mkdir -p "$mount_point/opt/manifests"
    mkdir -p "$mount_point/opt/helm-values"

    # Inject bootstrap common library
    log_info "Injecting bootstrap common library..."
    inject_file "$BOOTSTRAP_DIR/lib/bootstrap-common.sh" "opt/bootstrap/lib/bootstrap-common.sh" "755"

    # Inject node-specific bootstrap script
    if [ "$node_num" -eq 1 ]; then
        log_info "Injecting node1 initialization script..."
        inject_file "$BOOTSTRAP_DIR/node1-init.sh" "opt/bootstrap/node1-init.sh" "755"
    else
        log_info "Injecting node join script..."
        inject_file "$BOOTSTRAP_DIR/node-join.sh" "opt/bootstrap/node-join.sh" "755"
        # For join nodes, also embed the admin.conf (will be generated during build)
        if [ -f "$CREDENTIALS_DIR/admin.conf" ]; then
            inject_file "$CREDENTIALS_DIR/admin.conf" "opt/bootstrap/admin.conf" "600"
        fi
        # Embed join command
        if [ -f "$CREDENTIALS_DIR/join-command.sh" ]; then
            inject_file "$CREDENTIALS_DIR/join-command.sh" "opt/bootstrap/join-command.sh" "755"
        fi
    fi

    # Process and inject cloud-init
    log_info "Processing cloud-init template..."
    local cloud_init_template="$CLOUD_INIT_TEMPLATE_DIR/node${node_num}-user-data.yaml.tmpl"

    if [ ! -f "$cloud_init_template" ]; then
        log_warn "Cloud-init template not found: $cloud_init_template"
        log_warn "Using node1 template for all nodes"
        cloud_init_template="$CLOUD_INIT_TEMPLATE_DIR/node1-user-data.yaml.tmpl"
    fi

    # Export ALL variables for template processing
    export NODE_NUM=$node_num
    export NODE_HOSTNAME=$node_hostname
    export NODE_PRIVATE_IP=$node_private_ip
    export NODE_EXTERNAL_IP=$node_external_ip
    export SSH_PUBLIC_KEY="$(cat "$SSH_PUB_KEY_PATH")"

    # Generate password hash for console access (cloud-init compatible SHA-512)
    export SSH_PASSWORD_HASH="$(openssl passwd -6 "$SSH_PASSWORD")"

    # Export configuration variables from platform/.env
    export CLUSTER_NAME
    export SSH_USER
    export NETWORK_INTERFACE
    export NODE1_PRIVATE_IP=$(get_node_private_ip 1)
    export NODE1_EXTERNAL_IP=$(get_node_external_ip 1)
    export NODE2_PRIVATE_IP=$(get_node_private_ip 2)
    export NODE2_EXTERNAL_IP=$(get_node_external_ip 2)
    export NODE3_PRIVATE_IP=$(get_node_private_ip 3)
    export NODE3_EXTERNAL_IP=$(get_node_external_ip 3)
    export PRIVATE_NETMASK=24
    export EXTERNAL_NETMASK=24
    export PRIVATE_GATEWAY
    export VIP
    export METALLB_IP_RANGE
    export K8S_VERSION
    export POD_CIDR
    export SERVICE_CIDR
    export METALLB_VERSION
    export INGRESS_NGINX_VERSION
    export LONGHORN_VERSION
    export LONGHORN_DATA_DIR
    export DEPLOY_LONGHORN
    export DEPLOY_MINIO
    export DEPLOY_GRAFANA
    export DEPLOY_PROMETHEUS
    export DEPLOY_PORTAINER
    export DEPLOY_WELCOME_PAGE
    export GRAFANA_ADMIN_PASSWORD
    export MINIO_ROOT_USER
    export MINIO_ROOT_PASSWORD

    # Process template
    local processed_cloud_init="/tmp/user-data-node${node_num}.yaml"
    envsubst < "$cloud_init_template" > "$processed_cloud_init"

    # Create meta-data
    local meta_data="/tmp/meta-data-node${node_num}.yaml"
    cat > "$meta_data" <<EOF
instance-id: ${node_hostname}
local-hostname: ${node_hostname}
EOF

    # Inject cloud-init
    log_info "Injecting cloud-init configuration..."
    inject_cloud_init "$processed_cloud_init" "$meta_data"

    # Pre-configure network directly (bypass cloud-init for network)
    log_info "Pre-configuring network (node $node_num)..."

    # Remove cloud-init netplan config (has DHCP enabled, conflicts with static IP)
    rm -f "$MOUNT_POINT/etc/netplan/50-cloud-init.yaml"
    log_info "Removed 50-cloud-init.yaml (DHCP config)"

    # Write static network configuration with dual IPs
    cat > "$MOUNT_POINT/etc/netplan/01-netcfg.yaml" <<NETEOF
network:
  version: 2
  ethernets:
    ens3:
      dhcp4: false
      addresses:
        - $node_private_ip/24
        - $node_external_ip/24
      routes:
        - to: default
          via: ${PRIVATE_GATEWAY}
      nameservers:
        addresses:
          - 8.8.8.8
          - 8.8.4.4
NETEOF
    chmod 644 "$MOUNT_POINT/etc/netplan/01-netcfg.yaml"
    log_info "Static network configuration written"

    # Generate systemd-networkd configuration from netplan
    log_info "Generating systemd-networkd configuration..."
    chroot "$MOUNT_POINT" netplan generate

    # Copy generated files from /run to /etc for persistence (/run is tmpfs, wiped on boot)
    log_info "Copying network config to persistent storage..."
    if [ -d "$MOUNT_POINT/run/systemd/network" ]; then
        mkdir -p "$MOUNT_POINT/etc/systemd/network"
        cp -v "$MOUNT_POINT/run/systemd/network"/*.network "$MOUNT_POINT/etc/systemd/network/" 2>/dev/null || true
        log_info "Network configuration made persistent"
    fi

    # Create network configuration script
    log_info "Creating zero-touch network configuration script..."
    cat > "$MOUNT_POINT/usr/local/bin/zerotouch-network-setup.sh" <<'NETSCRIPT'
#!/bin/bash
# Zero-Touch Network Configuration
# Configures static IP on boot

LOG="/var/log/zerotouch-network.log"

{
    echo "==== Zero-Touch Network Config Start ===="
    date
    echo "Available interfaces:"
    ip link show

    echo "Configuring loopback..."
    ip link set lo up && echo "✓ lo up" || echo "✗ lo failed"

    echo "Waiting for ens3..."
    for i in {1..10}; do
        if ip link show ens3 &>/dev/null; then
            echo "✓ ens3 exists"
            break
        fi
        echo "Waiting for ens3... ($i/10)"
        sleep 1
    done

    echo "Configuring ens3..."
    ip link set ens3 up && echo "✓ ens3 up" || echo "✗ ens3 up failed"
    sleep 2

    ip addr flush dev ens3 && echo "✓ ens3 flushed" || echo "✗ flush failed"
    ip addr add NODE_PRIVATE_IP/24 dev ens3 && echo "✓ IP NODE_PRIVATE_IP added" || echo "✗ IP add failed"
    ip route add default via PRIVATE_GATEWAY && echo "✓ default route via PRIVATE_GATEWAY" || echo "✗ route failed"

    echo "Configuring DNS..."
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 8.8.4.4" >> /etc/resolv.conf
    echo "✓ DNS configured"

    echo ""
    echo "Final network state:"
    ip addr show
    echo ""
    ip route show
    echo ""
    echo "==== Zero-Touch Network Config Complete ===="
} >> "$LOG" 2>&1

exit 0
NETSCRIPT

    # Substitute variables in the script
    sed -i "s|NODE_PRIVATE_IP|$node_private_ip|g" "$MOUNT_POINT/usr/local/bin/zerotouch-network-setup.sh"
    sed -i "s|PRIVATE_GATEWAY|${PRIVATE_GATEWAY}|g" "$MOUNT_POINT/usr/local/bin/zerotouch-network-setup.sh"
    chmod +x "$MOUNT_POINT/usr/local/bin/zerotouch-network-setup.sh"
    log_info "Network setup script created"

    # Create systemd service for network configuration
    log_info "Creating zerotouch-network.service..."
    cat > "$MOUNT_POINT/etc/systemd/system/zerotouch-network.service" <<'NETSVC'
[Unit]
Description=Zero-Touch Network Configuration
After=systemd-networkd.service network.target
Before=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zerotouch-network-setup.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
NETSVC

    # Enable the service
    ln -sf /etc/systemd/system/zerotouch-network.service "$MOUNT_POINT/etc/systemd/system/multi-user.target.wants/zerotouch-network.service"
    log_info "zerotouch-network.service enabled"

    # Disable systemd-networkd-wait-online.service (blocks boot with static IP)
    log_info "Disabling systemd-networkd-wait-online.service..."
    rm -f "$MOUNT_POINT/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service"
    # Mask it to prevent re-enabling
    ln -sf /dev/null "$MOUNT_POINT/etc/systemd/system/systemd-networkd-wait-online.service"
    log_info "systemd-networkd-wait-online.service disabled"

    # Disable cloud-init network management (network handled by netplan directly)
    log_info "Disabling cloud-init network management..."
    cat > "$MOUNT_POINT/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg" <<'NETCFG'
# Disable cloud-init network management
# Network is pre-configured in /etc/netplan/01-netcfg.yaml
network:
  config: disabled
NETCFG

    # Force NoCloud datasource for remaining cloud-init tasks (user creation, scripts)
    log_info "Configuring NoCloud datasource..."
    cat > "$MOUNT_POINT/etc/cloud/cloud.cfg.d/99-nocloud.cfg" <<'CFGEOF'
# Force NoCloud datasource
datasource_list: [ NoCloud, None ]
datasource:
  NoCloud:
    seedfrom: /var/lib/cloud/seed/nocloud/
CFGEOF

    # Fix CNI plugin path for kubelet compatibility
    # Kubernetes CNI plugins are installed in /opt/cni/bin but kubelet looks for them in /usr/lib/cni
    log_info "Creating CNI plugin symlinks for kubelet compatibility..."
    mkdir -p "$MOUNT_POINT/usr/lib/cni"
    # Create symlinks for all CNI plugins
    for plugin in "$MOUNT_POINT/opt/cni/bin"/*; do
        if [ -f "$plugin" ]; then
            plugin_name=$(basename "$plugin")
            ln -sf "/opt/cni/bin/$plugin_name" "$MOUNT_POINT/usr/lib/cni/$plugin_name"
        fi
    done
    log_info "CNI plugin symlinks created"

    # Configure systemd-resolved DNS settings
    log_info "Configuring DNS via systemd-resolved..."
    cat > "$MOUNT_POINT/usr/local/bin/zerotouch-dns-setup.sh" <<'DNSSCRIPT'
#!/bin/bash
# Zero-Touch DNS Configuration
# Configures systemd-resolved to use Google DNS

LOG="/var/log/zerotouch-dns.log"

{
    echo "==== Zero-Touch DNS Configuration Start ===="
    date

    # Wait for systemd-resolved to be ready
    for i in {1..10}; do
        if systemctl is-active systemd-resolved &>/dev/null; then
            echo "✓ systemd-resolved is active"
            break
        fi
        echo "Waiting for systemd-resolved... ($i/10)"
        sleep 1
    done

    # Configure DNS for ens3 interface
    echo "Configuring DNS servers for ens3..."
    resolvectl dns ens3 8.8.8.8 8.8.4.4 && echo "✓ DNS servers set" || echo "✗ Failed to set DNS servers"

    # Set default routing domain to enable DNS for all queries
    echo "Configuring routing domain..."
    resolvectl domain ens3 '~.' && echo "✓ Routing domain set" || echo "✗ Failed to set routing domain"

    # Verify configuration
    echo ""
    echo "DNS Configuration:"
    resolvectl status ens3 2>/dev/null || echo "Could not get DNS status"

    # Test DNS resolution
    echo ""
    echo "Testing DNS resolution..."
    if host google.com 8.8.8.8 &>/dev/null; then
        echo "✓ DNS resolution working"
    else
        echo "⚠ DNS resolution test failed"
    fi

    echo ""
    echo "==== Zero-Touch DNS Configuration Complete ===="
} >> "$LOG" 2>&1

exit 0
DNSSCRIPT

    chmod +x "$MOUNT_POINT/usr/local/bin/zerotouch-dns-setup.sh"
    log_info "DNS setup script created"

    # Create systemd service for DNS configuration
    log_info "Creating zerotouch-dns.service..."
    cat > "$MOUNT_POINT/etc/systemd/system/zerotouch-dns.service" <<'DNSSVC'
[Unit]
Description=Zero-Touch DNS Configuration
After=systemd-resolved.service network-online.target zerotouch-network.service
Wants=systemd-resolved.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zerotouch-dns-setup.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
DNSSVC

    # Enable the DNS service
    ln -sf /etc/systemd/system/zerotouch-dns.service "$MOUNT_POINT/etc/systemd/system/multi-user.target.wants/zerotouch-dns.service"
    log_info "zerotouch-dns.service enabled"

    # Clean cloud-init state to force re-run on first boot
    log_info "Cleaning cloud-init state..."
    rm -rf "$MOUNT_POINT/var/lib/cloud/instances"
    rm -rf "$MOUNT_POINT/var/lib/cloud/instance"
    rm -rf "$MOUNT_POINT/var/lib/cloud/sem"
    rm -f "$MOUNT_POINT/var/lib/cloud/data/instance-id"
    rm -f "$MOUNT_POINT/var/lib/cloud/data/previous-instance-id"
    rm -f "$MOUNT_POINT/var/log/cloud-init*.log"
    # Recreate sem directory
    mkdir -p "$MOUNT_POINT/var/lib/cloud/sem"

    # Unmount image
    log_info "Unmounting image..."
    unmount_image

    log_success "Node $node_num image customization complete: $output_image"
}

################################################################################
# Main
################################################################################

log_info "=========================================="
log_info "Zero-Touch Image Customization"
log_info "=========================================="
log_info "Platform: $BUILD_PLATFORM"
log_info "Base Image: $BASE_IMAGE"
log_info "Output Directory: $OUTPUT_DIR"
log_info "=========================================="

# Check prerequisites
if [ ! -f "$BASE_IMAGE" ]; then
    log_error "Base image not found: $BASE_IMAGE"
    log_error "Please build base image first using OSBuild"
    exit 1
fi

# Create output directories
mkdir -p "$OUTPUT_DIR"
mkdir -p "$BUILD_WORK_DIR"

# Check if SSH key exists
if [ ! -f "$SSH_PUB_KEY_PATH" ]; then
    log_error "SSH public key not found: $SSH_PUB_KEY_PATH"
    log_error "Please generate credentials first"
    exit 1
fi

# Customize images
log_info "Customizing images for $NODE_COUNT nodes..."

for node_num in $(seq 1 $NODE_COUNT); do
    output_image="$OUTPUT_DIR/${CLUSTER_NAME}-node${node_num}.img"
    customize_node_image $node_num "$BASE_IMAGE" "$output_image"
done

log_info "=========================================="
log_success "All images customized successfully!"
log_info "=========================================="
log_info "Output images:"
for node_num in $(seq 1 $NODE_COUNT); do
    output_image="$OUTPUT_DIR/${CLUSTER_NAME}-node${node_num}.img"
    log_info "  Node $node_num: $output_image"
done
log_info "=========================================="

exit 0
