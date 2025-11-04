#!/bin/bash
#
# bootstrap.sh - First-boot provisioning script
#
# This script is baked into the OS image at /opt/bootstrap/bootstrap.sh
# It runs on every boot via first-boot.service and provisions the node
# if it hasn't been provisioned yet.
#

set -euo pipefail

# Configuration
STATE_FILE="/var/lib/node-provisioned"
LOG_FILE="/var/log/bootstrap.log"
BOOTSTRAP_REPO="${BOOTSTRAP_REPO:-https://github.com/altyrus/k8s-bootstrap.git}"
BOOTSTRAP_BRANCH="${BOOTSTRAP_BRANCH:-main}"
CONFIG_ENDPOINT="${CONFIG_ENDPOINT:-}"

# Logging
log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" | tee -a "$LOG_FILE" >&2
}

# Multi-factor first-boot detection
is_first_boot() {
    # Check 1: State file exists
    if [[ -f "$STATE_FILE" ]]; then
        log "State file exists, already provisioned"
        return 1
    fi

    # Check 2: kubelet is running
    if systemctl is-active --quiet kubelet 2>/dev/null; then
        log "kubelet is active, already provisioned"
        return 1
    fi

    # Check 3: Node is in cluster (if kubectl is available)
    if command -v kubectl &>/dev/null; then
        if kubectl get node "$(hostname)" 2>/dev/null; then
            log "Node is in cluster, already provisioned"
            return 1
        fi
    fi

    log "First boot detected"
    return 0
}

# Detect boot mode (netboot vs NVMe)
get_boot_mode() {
    if grep -q "nfsroot" /proc/cmdline 2>/dev/null; then
        echo "netboot"
    elif [[ -b /dev/nvme0n1 ]]; then
        echo "nvme"
    else
        echo "unknown"
    fi
}

# Get node identity
get_node_identity() {
    local mac serial

    # Get MAC address (eth0 or first available interface)
    if [[ -f /sys/class/net/eth0/address ]]; then
        mac=$(cat /sys/class/net/eth0/address | tr -d ':' | tr '[:lower:]' '[:upper:]')
    else
        mac=$(ip link show | grep -m1 ether | awk '{print $2}' | tr -d ':' | tr '[:lower:]' '[:upper:]')
    fi

    # Get serial number from cpuinfo
    if [[ -f /proc/cpuinfo ]]; then
        serial=$(grep Serial /proc/cpuinfo | cut -d ' ' -f 2 | tail -1)
    else
        serial="unknown"
    fi

    echo "{\"mac\":\"${mac}\",\"serial\":\"${serial}\",\"boot_mode\":\"$(get_boot_mode)\"}"
}

# Fetch bootstrap scripts from git
fetch_bootstrap_scripts() {
    local temp_dir
    temp_dir=$(mktemp -d)

    log "Cloning bootstrap repository: ${BOOTSTRAP_REPO}"

    if git clone --depth 1 --branch "${BOOTSTRAP_BRANCH}" "${BOOTSTRAP_REPO}" "${temp_dir}/bootstrap" 2>&1 | tee -a "$LOG_FILE"; then
        echo "${temp_dir}/bootstrap"
        return 0
    else
        log_error "Failed to clone bootstrap repository"
        rm -rf "${temp_dir}"
        return 1
    fi
}

# Query configuration endpoint (if available)
query_config_endpoint() {
    local identity="$1"

    if [[ -z "$CONFIG_ENDPOINT" ]]; then
        log "No config endpoint configured"
        echo "{}"
        return 0
    fi

    log "Querying config endpoint: ${CONFIG_ENDPOINT}"

    local mac serial
    mac=$(echo "$identity" | jq -r .mac)
    serial=$(echo "$identity" | jq -r .serial)

    if curl -sf -m 10 "${CONFIG_ENDPOINT}?mac=${mac}&serial=${serial}" 2>&1 | tee -a "$LOG_FILE"; then
        return 0
    else
        log_error "Failed to query config endpoint"
        echo "{}"
        return 1
    fi
}

# Execute bootstrap scripts with retry
execute_bootstrap() {
    local bootstrap_dir="$1"
    local node_identity="$2"
    local max_attempts=3
    local attempt

    # Export variables for bootstrap scripts
    export NODE_IDENTITY="$node_identity"
    export BOOT_MODE=$(get_boot_mode)

    for attempt in $(seq 1 $max_attempts); do
        log "Bootstrap attempt ${attempt}/${max_attempts}"

        if [[ -x "${bootstrap_dir}/setup.sh" ]]; then
            if "${bootstrap_dir}/setup.sh" 2>&1 | tee -a "$LOG_FILE"; then
                log "Bootstrap completed successfully"
                return 0
            else
                log_error "Bootstrap attempt ${attempt} failed"
            fi
        else
            log_error "Bootstrap script not found or not executable: ${bootstrap_dir}/setup.sh"
            return 1
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log "Waiting 10 seconds before retry..."
            sleep 10
        fi
    done

    log_error "Bootstrap failed after ${max_attempts} attempts"
    return 1
}

# Mark node as provisioned
mark_provisioned() {
    local node_identity="$1"

    mkdir -p "$(dirname "$STATE_FILE")"

    cat > "$STATE_FILE" <<EOF
{
    "provisioned_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "node_identity": ${node_identity},
    "bootstrap_repo": "${BOOTSTRAP_REPO}",
    "bootstrap_branch": "${BOOTSTRAP_BRANCH}"
}
EOF

    log "Node marked as provisioned"
}

# Main execution
main() {
    log "=========================================="
    log "Bootstrap script started"
    log "Hostname: $(hostname)"
    log "Boot mode: $(get_boot_mode)"
    log "=========================================="

    # Check if already provisioned
    if ! is_first_boot; then
        log "Node already provisioned, exiting"
        exit 0
    fi

    log "Starting first-boot provisioning"

    # Wait for network
    log "Waiting for network connectivity..."
    for i in {1..30}; do
        if ping -c 1 -W 1 8.8.8.8 &>/dev/null; then
            log "Network is available"
            break
        fi
        if [[ $i -eq 30 ]]; then
            log_error "Network not available after 30 seconds"
            exit 1
        fi
        sleep 1
    done

    # Get node identity
    log "Detecting node identity"
    NODE_IDENTITY=$(get_node_identity)
    log "Node identity: ${NODE_IDENTITY}"

    # Query config endpoint (optional)
    if [[ -n "$CONFIG_ENDPOINT" ]]; then
        NODE_CONFIG=$(query_config_endpoint "$NODE_IDENTITY")
        export NODE_CONFIG
        log "Node config: ${NODE_CONFIG}"
    fi

    # Fetch bootstrap scripts
    log "Fetching bootstrap scripts"
    BOOTSTRAP_DIR=$(fetch_bootstrap_scripts)

    if [[ -z "$BOOTSTRAP_DIR" ]]; then
        log_error "Failed to fetch bootstrap scripts"
        exit 1
    fi

    log "Bootstrap scripts fetched to: ${BOOTSTRAP_DIR}"

    # Execute bootstrap
    log "Executing bootstrap scripts"
    if execute_bootstrap "$BOOTSTRAP_DIR" "$NODE_IDENTITY"; then
        mark_provisioned "$NODE_IDENTITY"
        log "=========================================="
        log "Bootstrap completed successfully"
        log "=========================================="

        # Cleanup
        rm -rf "$BOOTSTRAP_DIR"
        exit 0
    else
        log_error "=========================================="
        log_error "Bootstrap failed"
        log_error "=========================================="

        # Cleanup
        rm -rf "$BOOTSTRAP_DIR"
        exit 1
    fi
}

# Run main function
main "$@"
