#!/bin/bash
################################################################################
# Node Join Bootstrap
#
# This script runs on nodes 2/3 and joins them to the cluster as control-plane
# nodes for HA.
#
# Timeline: ~5 minutes to join
################################################################################

# Source common library
source /opt/bootstrap/lib/bootstrap-common.sh

log_header "NODE JOIN STARTING"

# Read node-specific configuration from environment
NODE_NUM="${NODE_NUM:-2}"
PRIVATE_IP="${NODE_PRIVATE_IP}"
NODE_NAME="$(hostname)"

log_info "Node: $NODE_NAME ($NODE_NUM)"
log_info "Private IP: $PRIVATE_IP"

################################################################################
# STEP 1: System Prerequisites
################################################################################

if ! skip_if_complete "prerequisites"; then
    log_step "1" "Verifying System Prerequisites"

    disable_swap
    configure_kernel_modules
    configure_sysctl
    ensure_service_running containerd
    systemctl enable kubelet 2>&1 | tee -a "$BOOTSTRAP_LOG"

    mark_complete "prerequisites"
fi

################################################################################
# STEP 2: Wait for Node 1 API Server
################################################################################

if ! skip_if_complete "wait-node1"; then
    log_step "2" "Waiting for Node 1 API Server"

    NODE1_IP="${NODE1_PRIVATE_IP:-192.168.100.11}"
    log_info "Waiting for API server at $NODE1_IP:6443..."

    wait_for_api_server "$NODE1_IP:6443"

    mark_complete "wait-node1"
fi

################################################################################
# STEP 3: Wait for Cluster Ready Signal
################################################################################

if ! skip_if_complete "wait-cluster-ready"; then
    log_step "3" "Waiting for Cluster Ready Signal"

    export KUBECONFIG=/opt/bootstrap/admin.conf

    # Copy admin.conf from node1 (should be pre-embedded in image)
    if [ ! -f "$KUBECONFIG" ]; then
        log_error "admin.conf not found at $KUBECONFIG"
        log_error "This file should be embedded in the image by the build process"
        die "Cannot proceed without kubeconfig"
    fi

    log_info "Waiting for cluster-ready ConfigMap..."
    wait_for_condition \
        "kubectl --kubeconfig=$KUBECONFIG get configmap cluster-ready -n kube-system" \
        "Cluster ready signal" \
        1800  # 30 minutes max

    mark_complete "wait-cluster-ready"
fi

################################################################################
# STEP 4: Join Cluster
################################################################################

if ! skip_if_complete "join-cluster"; then
    log_step "4" "Joining Cluster as Control Plane"

    # Read join command from embedded file (created during image build)
    if [ ! -f "/opt/bootstrap/join-command.sh" ]; then
        log_error "Join command not found at /opt/bootstrap/join-command.sh"
        log_error "This file should be embedded in the image by the build process"
        die "Cannot proceed without join command"
    fi

    log_info "Executing join command..."
    bash /opt/bootstrap/join-command.sh --apiserver-advertise-address=$PRIVATE_IP 2>&1 | tee -a "$BOOTSTRAP_LOG"

    if [ $? -eq 0 ]; then
        log_success "Successfully joined cluster"
    else
        die "Failed to join cluster"
    fi

    # Setup kubeconfig for this node
    mkdir -p $HOME/.kube
    cp /etc/kubernetes/admin.conf $HOME/.kube/config 2>/dev/null || true

    mark_complete "join-cluster"
fi

################################################################################
# FINAL STEPS
################################################################################

export KUBECONFIG=/etc/kubernetes/admin.conf

log_header "NODE JOIN COMPLETE"
log_success "Node $(hostname) successfully joined cluster!"
log ""
log_info "Checking cluster nodes..."
kubectl get nodes 2>&1 | tee -a "$BOOTSTRAP_LOG" || true
log ""
log_info "Total join time: $SECONDS seconds"

# Cleanup
if [ "${CLEANUP_BOOTSTRAP:-true}" = "true" ]; then
    cleanup_bootstrap
fi

log_header "NODE JOIN BOOTSTRAP COMPLETE"

exit 0
