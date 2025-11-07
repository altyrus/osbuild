#!/bin/bash
################################################################################
# Bootstrap Common Library
#
# Shared utilities for zero-touch Kubernetes bootstrap scripts.
# This file is sourced by both node1-init.sh and node-join.sh.
################################################################################

# Exit on error
set -e
set -o pipefail

################################################################################
# CONFIGURATION
################################################################################

# Bootstrap paths
BOOTSTRAP_DIR="/opt/bootstrap"
BOOTSTRAP_LOG="${BOOTSTRAP_LOG:-/var/log/bootstrap.log}"
BOOTSTRAP_STATE_DIR="${BOOTSTRAP_STATE_DIR:-/opt/bootstrap/.state}"
MANIFESTS_DIR="/opt/manifests"
HELM_VALUES_DIR="/opt/helm-values"

# Timing
WAIT_INTERVAL=10
API_SERVER_WAIT_MAX=60  # 10 minutes
POD_WAIT_MAX=120  # 20 minutes

################################################################################
# LOGGING
################################################################################

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'  # No Color

# Timestamp for logging
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Logging functions (both stdout and log file)
log() {
    local msg="[$(timestamp)] $*"
    echo "$msg" | tee -a "$BOOTSTRAP_LOG"
}

log_header() {
    local msg="$*"
    log ""
    log "=========================================================================="
    log "$msg"
    log "=========================================================================="
}

log_subheader() {
    local msg="$*"
    log ""
    log "----------------------------------------------------------------------"
    log "$msg"
    log "----------------------------------------------------------------------"
}

log_info() {
    local msg="$*"
    echo -e "${GREEN}[INFO] $(timestamp)${NC} $msg" | tee -a "$BOOTSTRAP_LOG"
}

log_success() {
    local msg="$*"
    echo -e "${GREEN}[SUCCESS] $(timestamp)${NC} ✓ $msg" | tee -a "$BOOTSTRAP_LOG"
}

log_warn() {
    local msg="$*"
    echo -e "${YELLOW}[WARN] $(timestamp)${NC} $msg" | tee -a "$BOOTSTRAP_LOG"
}

log_error() {
    local msg="$*"
    echo -e "${RED}[ERROR] $(timestamp)${NC} ✗ $msg" | tee -a "$BOOTSTRAP_LOG"
}

log_debug() {
    local msg="$*"
    echo -e "${BLUE}[DEBUG] $(timestamp)${NC} $msg" | tee -a "$BOOTSTRAP_LOG"
}

log_step() {
    local step="$1"
    local desc="$2"
    log ""
    log_info "[$step] $desc"
}

################################################################################
# ERROR HANDLING
################################################################################

die() {
    log_error "$*"
    exit 1
}

# Error handler
error_handler() {
    local line=$1
    log_error "Script failed at line $line"
    log_error "Last command exit code: $?"
    log_error "Bootstrap FAILED. Check $BOOTSTRAP_LOG for details."
}

trap 'error_handler ${LINENO}' ERR

################################################################################
# STATE MANAGEMENT
################################################################################

init_state_dir() {
    mkdir -p "$BOOTSTRAP_STATE_DIR"
}

mark_complete() {
    local step="$1"
    init_state_dir
    touch "$BOOTSTRAP_STATE_DIR/${step}.done"
    log_debug "Marked step complete: $step"
}

is_complete() {
    local step="$1"
    [ -f "$BOOTSTRAP_STATE_DIR/${step}.done" ]
}

skip_if_complete() {
    local step="$1"
    local desc="$2"
    if is_complete "$step"; then
        log_info "Skipping $desc (already complete)"
        return 0
    fi
    return 1
}

################################################################################
# RETRY LOGIC
################################################################################

retry() {
    local max_attempts="$1"
    local wait_time="$2"
    shift 2
    local command="$@"

    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        log_debug "Attempt $attempt/$max_attempts: $command"
        if eval "$command"; then
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            log_warn "Command failed, retrying in ${wait_time}s..."
            sleep "$wait_time"
        fi
        ((attempt++))
    done

    log_error "Command failed after $max_attempts attempts: $command"
    return 1
}

################################################################################
# WAIT FUNCTIONS
################################################################################

wait_for_condition() {
    local condition="$1"
    local description="$2"
    local max_wait="${3:-$POD_WAIT_MAX}"
    local interval="${4:-$WAIT_INTERVAL}"

    log_info "Waiting for: $description (max ${max_wait}s)"

    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        if eval "$condition" >/dev/null 2>&1; then
            log_success "$description (${elapsed}s)"
            return 0
        fi
        sleep "$interval"
        ((elapsed += interval))

        # Progress indicator every 30 seconds
        if [ $((elapsed % 30)) -eq 0 ]; then
            log_debug "Still waiting... (${elapsed}/${max_wait}s)"
        fi
    done

    log_error "Timeout waiting for: $description (${max_wait}s)"
    return 1
}

wait_for_api_server() {
    local api_endpoint="${1:-localhost:6443}"
    wait_for_condition \
        "curl -k -s https://$api_endpoint/healthz | grep -q ok" \
        "Kubernetes API server at $api_endpoint" \
        $((API_SERVER_WAIT_MAX * WAIT_INTERVAL))
}

wait_for_pods() {
    local namespace="$1"
    local label="$2"
    local timeout="${3:-$((POD_WAIT_MAX * WAIT_INTERVAL))}"

    log_info "Waiting for pods in $namespace with label $label"

    kubectl wait --for=condition=ready pod \
        -l "$label" \
        -n "$namespace" \
        --timeout="${timeout}s" 2>&1 | tee -a "$BOOTSTRAP_LOG"

    return ${PIPESTATUS[0]}
}

wait_for_deployment() {
    local namespace="$1"
    local deployment="$2"
    local timeout="${3:-300}"

    log_info "Waiting for deployment $deployment in $namespace"

    kubectl rollout status deployment/"$deployment" \
        -n "$namespace" \
        --timeout="${timeout}s" 2>&1 | tee -a "$BOOTSTRAP_LOG"

    return ${PIPESTATUS[0]}
}

wait_for_daemonset() {
    local namespace="$1"
    local daemonset="$2"
    local timeout="${3:-300}"

    log_info "Waiting for daemonset $daemonset in $namespace"

    local deadline=$(($(date +%s) + timeout))
    while [ $(date +%s) -lt $deadline ]; do
        local desired=$(kubectl get daemonset "$daemonset" -n "$namespace" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
        local ready=$(kubectl get daemonset "$daemonset" -n "$namespace" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")

        if [ "$desired" -gt 0 ] && [ "$ready" -eq "$desired" ]; then
            log_success "Daemonset $daemonset ready ($ready/$desired)"
            return 0
        fi

        log_debug "Daemonset $daemonset: $ready/$desired pods ready"
        sleep "$WAIT_INTERVAL"
    done

    log_error "Timeout waiting for daemonset $daemonset"
    return 1
}

################################################################################
# KUBERNETES HELPERS
################################################################################

export KUBECONFIG=/etc/kubernetes/admin.conf

kubectl_retry() {
    retry 3 5 kubectl "$@"
}

apply_manifest() {
    local manifest="$1"
    local description="${2:-manifest}"

    log_info "Applying $description"

    if [ ! -f "$manifest" ]; then
        log_error "Manifest not found: $manifest"
        return 1
    fi

    kubectl_retry apply -f "$manifest"
    log_success "$description applied"
}

apply_manifest_url() {
    local url="$1"
    local description="${2:-$url}"

    log_info "Applying $description from URL"
    retry 3 5 kubectl apply -f "$url" 2>&1 | tee -a "$BOOTSTRAP_LOG"

    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_success "$description applied"
        return 0
    else
        log_error "Failed to apply $description"
        return 1
    fi
}

create_namespace() {
    local namespace="$1"

    if kubectl get namespace "$namespace" >/dev/null 2>&1; then
        log_debug "Namespace $namespace already exists"
        return 0
    fi

    log_info "Creating namespace: $namespace"
    kubectl create namespace "$namespace"
    log_success "Namespace $namespace created"
}

################################################################################
# HELM HELPERS
################################################################################

helm_add_repo() {
    local repo_name="$1"
    local repo_url="$2"

    log_info "Adding Helm repository: $repo_name"

    helm repo add "$repo_name" "$repo_url" 2>&1 | tee -a "$BOOTSTRAP_LOG"
    helm repo update 2>&1 | tee -a "$BOOTSTRAP_LOG"

    log_success "Helm repository $repo_name added"
}

helm_install() {
    local release="$1"
    local chart="$2"
    local namespace="$3"
    shift 3
    local extra_args="$@"

    log_info "Installing Helm chart: $release ($chart) in $namespace"

    create_namespace "$namespace"

    helm install "$release" "$chart" \
        --namespace "$namespace" \
        $extra_args 2>&1 | tee -a "$BOOTSTRAP_LOG"

    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_success "Helm release $release installed"
        return 0
    else
        log_error "Helm release $release failed"
        return 1
    fi
}

################################################################################
# NETWORK HELPERS
################################################################################

configure_network() {
    local interface="$1"
    local primary_ip="$2"
    local primary_netmask="$3"
    local gateway="$4"
    local secondary_ip="${5:-}"
    local secondary_netmask="${6:-}"

    log_info "Configuring network on $interface"
    log_info "  Primary: $primary_ip/$primary_netmask"
    if [ -n "$secondary_ip" ]; then
        log_info "  Secondary: $secondary_ip/$secondary_netmask"
    fi
    log_info "  Gateway: $gateway"

    # Generate netplan configuration
    local netplan_config="/etc/netplan/01-netcfg.yaml"

    cat > "$netplan_config" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $interface:
      dhcp4: false
      addresses:
        - $primary_ip/$primary_netmask
EOF

    # Add secondary IP if provided
    if [ -n "$secondary_ip" ]; then
        cat >> "$netplan_config" <<EOF
        - $secondary_ip/$secondary_netmask
EOF
    fi

    # Add routes and gateway
    cat >> "$netplan_config" <<EOF
      routes:
        - to: default
          via: $gateway
      nameservers:
        addresses:
          - 8.8.8.8
          - 8.8.4.4
EOF

    log_debug "Netplan configuration created"

    # Apply netplan
    netplan apply 2>&1 | tee -a "$BOOTSTRAP_LOG"

    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_success "Network configured"
        sleep 5  # Wait for network to stabilize
        return 0
    else
        log_error "Network configuration failed"
        return 1
    fi
}

test_network() {
    log_info "Testing network connectivity"

    local max_attempts=5
    local attempt=1

    # Test internet with retries (network might not be fully up yet)
    while [ $attempt -le $max_attempts ]; do
        if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
            log_success "Network connectivity OK (attempt $attempt/$max_attempts)"
            return 0
        fi
        log_warn "Cannot reach 8.8.8.8 (attempt $attempt/$max_attempts)"
        attempt=$((attempt + 1))
        if [ $attempt -le $max_attempts ]; then
            sleep 5
        fi
    done

    log_error "Network test failed after $max_attempts attempts"
    return 1
}

################################################################################
# SERVICE HELPERS
################################################################################

ensure_service_running() {
    local service="$1"

    log_info "Ensuring $service is running"

    systemctl enable "$service" 2>&1 | tee -a "$BOOTSTRAP_LOG"
    systemctl start "$service" 2>&1 | tee -a "$BOOTSTRAP_LOG"

    if systemctl is-active --quiet "$service"; then
        log_success "$service is running"
        return 0
    else
        log_error "$service failed to start"
        return 1
    fi
}

################################################################################
# SYSTEM HELPERS
################################################################################

disable_swap() {
    log_info "Disabling swap"
    swapoff -a
    sed -i '/swap/d' /etc/fstab
    systemctl mask swap.target 2>&1 | tee -a "$BOOTSTRAP_LOG"
    log_success "Swap disabled"
}

configure_kernel_modules() {
    log_info "Configuring kernel modules"

    cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

    modprobe overlay
    modprobe br_netfilter

    log_success "Kernel modules configured"
}

configure_sysctl() {
    log_info "Configuring sysctl for Kubernetes"

    cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

    sysctl --system >/dev/null 2>&1

    log_success "Sysctl configured"
}

################################################################################
# CLEANUP
################################################################################

cleanup_bootstrap() {
    log_info "Cleaning up bootstrap scripts (keeping logs)"

    # Remove bootstrap scripts but keep logs and state
    rm -f /opt/bootstrap/*.sh 2>/dev/null || true

    # Remove cloud-init to prevent re-running
    rm -f /boot/firmware/user-data /boot/firmware/meta-data 2>/dev/null || true
    rm -f /boot/user-data /boot/meta-data 2>/dev/null || true

    log_success "Bootstrap cleanup complete"
}

################################################################################
# INITIALIZATION
################################################################################

# Initialize logging
mkdir -p "$(dirname "$BOOTSTRAP_LOG")"
touch "$BOOTSTRAP_LOG"
chmod 644 "$BOOTSTRAP_LOG"

# Initialize state directory
init_state_dir

# Log script start
log_header "Bootstrap script started: $(basename "$0")"
log_info "Hostname: $(hostname)"
log_info "IP addresses: $(hostname -I)"
log_info "Kernel: $(uname -r)"
log_info "Log file: $BOOTSTRAP_LOG"
