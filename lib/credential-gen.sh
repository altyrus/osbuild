#!/bin/bash
################################################################################
# Credential Generation Utilities
#
# Generates SSH keys, kubeadm tokens, certificates, and passwords
# for zero-touch Kubernetes deployment.
################################################################################

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

################################################################################
# SSH Key Generation
################################################################################

generate_ssh_key() {
    local key_path="$1"
    local key_comment="${2:-zero-touch-k8s}"

    log_info "Generating SSH key pair at $key_path"

    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$key_path")"

    # Generate Ed25519 key (more secure and faster than RSA)
    ssh-keygen -t ed25519 -f "$key_path" -N "" -C "$key_comment" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        log_info "SSH key pair generated successfully"
        chmod 600 "$key_path"
        chmod 644 "${key_path}.pub"
        return 0
    else
        log_error "Failed to generate SSH key pair"
        return 1
    fi
}

################################################################################
# Kubeadm Token Generation
################################################################################

generate_kubeadm_token() {
    # Generate a valid kubeadm token (format: [a-z0-9]{6}.[a-z0-9]{16})
    local part1=$(openssl rand -hex 3)
    local part2=$(openssl rand -hex 8)
    echo "${part1}.${part2}"
}

################################################################################
# Certificate Key Generation
################################################################################

generate_certificate_key() {
    # Generate a 32-byte hex string for certificate encryption
    openssl rand -hex 32
}

################################################################################
# Password Generation
################################################################################

generate_password() {
    local length="${1:-32}"
    # Generate alphanumeric password without special characters
    openssl rand -base64 48 | tr -d '/+=' | cut -c1-${length}
}

################################################################################
# CA Certificate and Key Generation (for kubeadm)
################################################################################

generate_ca_cert() {
    local cert_dir="$1"
    local cluster_name="${2:-kubernetes}"

    log_info "Generating CA certificate in $cert_dir"

    mkdir -p "$cert_dir"

    # Generate CA private key
    openssl genrsa -out "$cert_dir/ca.key" 2048 2>/dev/null

    # Generate CA certificate
    openssl req -x509 -new -nodes \
        -key "$cert_dir/ca.key" \
        -subj "/CN=${cluster_name}-ca" \
        -days 36500 \
        -out "$cert_dir/ca.crt" 2>/dev/null

    if [ $? -eq 0 ]; then
        log_info "CA certificate generated successfully"
        chmod 600 "$cert_dir/ca.key"
        chmod 644 "$cert_dir/ca.crt"
        return 0
    else
        log_error "Failed to generate CA certificate"
        return 1
    fi
}

################################################################################
# Generate all credentials
################################################################################

generate_all_credentials() {
    local output_dir="$1"

    log_info "Generating all credentials in $output_dir"

    mkdir -p "$output_dir"

    # Generate SSH key
    generate_ssh_key "$output_dir/id_rsa" "zero-touch-k8s-$(date +%Y%m%d)"

    # Generate kubeadm token
    local token=$(generate_kubeadm_token)
    echo "$token" > "$output_dir/kubeadm-token.txt"
    log_info "Kubeadm token: $token"

    # Generate certificate key
    local cert_key=$(generate_certificate_key)
    echo "$cert_key" > "$output_dir/certificate-key.txt"
    log_info "Certificate key generated"

    # Generate MinIO password if not set
    if [ -z "$MINIO_ROOT_PASSWORD" ]; then
        local minio_pass=$(generate_password 32)
        echo "$minio_pass" > "$output_dir/minio-password.txt"
        export MINIO_ROOT_PASSWORD="$minio_pass"
        log_info "MinIO password generated"
    fi

    # Create cluster-info file
    cat > "$output_dir/cluster-info.txt" <<EOF
################################################################################
# Zero-Touch Kubernetes Cluster Information
################################################################################

Generated: $(date)
Platform: ${BUILD_PLATFORM:-unknown}
Cluster Name: ${CLUSTER_NAME:-k8s}

## Network Configuration

Private Network: ${PRIVATE_SUBNET:-192.168.100.0/24}
  Node 1: ${NODE1_PRIVATE_IP:-192.168.100.11}
  Node 2: ${NODE2_PRIVATE_IP:-192.168.100.12}
  Node 3: ${NODE3_PRIVATE_IP:-192.168.100.13}

External Network: ${EXTERNAL_SUBNET:-192.168.1.0/24}
  VIP: ${VIP:-192.168.1.100}
  Node 1: ${NODE1_EXTERNAL_IP:-192.168.1.11}
  Node 2: ${NODE2_EXTERNAL_IP:-192.168.1.12}
  Node 3: ${NODE3_EXTERNAL_IP:-192.168.1.13}

## Access Information

SSH Access:
  User: ${SSH_USER:-k8sadmin}
  Key: $output_dir/id_rsa
  Command: ssh -i $output_dir/id_rsa ${SSH_USER:-k8sadmin}@${NODE1_PRIVATE_IP:-192.168.100.11}

Kubernetes API:
  Endpoint: https://${NODE1_PRIVATE_IP:-192.168.100.11}:6443
  Kubeconfig: Will be generated at /opt/bootstrap/kubeconfig on node1

## Service URLs (via VIP: ${VIP:-192.168.1.100})

  Welcome Page: http://${VIP:-192.168.1.100}/
  Portainer: http://${VIP:-192.168.1.100}/portainer/
  Grafana: http://${VIP:-192.168.1.100}/grafana/
    Username: admin
    Password: ${GRAFANA_ADMIN_PASSWORD:-admin}
  Prometheus: http://${VIP:-192.168.1.100}/prometheus/
  Longhorn UI: http://${VIP:-192.168.1.100}/longhorn/
  MinIO Console: http://${VIP:-192.168.1.100}/minio/
    Username: ${MINIO_ROOT_USER:-admin}
    Password: ${MINIO_ROOT_PASSWORD:-<see minio-password.txt>}

## Cluster Credentials

Kubeadm Token: $token
Certificate Key: $cert_key

## Deployment Timeline

Node 1 (single-node functional):
  - Boot: 0:00
  - Network ready: 0:30
  - Kubernetes initialized: 3:00
  - CNI deployed: 5:00
  - MetalLB deployed: 7:00
  - Ingress deployed: 9:00
  - Storage deployed: 12:00
  - Monitoring deployed: 15:00
  - All services ready: ~18:00

Node 2/3 (join for HA):
  - Boot: 0:00
  - Wait for node1: 1:00
  - Join cluster: 3:00
  - HA enabled: 5:00

## Troubleshooting

Bootstrap Log: /var/log/bootstrap.log (on each node)
View in real-time: tail -f /var/log/bootstrap.log

Check cluster status:
  kubectl --kubeconfig=/opt/bootstrap/kubeconfig get nodes
  kubectl --kubeconfig=/opt/bootstrap/kubeconfig get pods -A

Check service status:
  systemctl status kubelet
  systemctl status containerd

## Files on Nodes

Node 1:
  - /opt/bootstrap/node1-init.sh (bootstrap script)
  - /opt/bootstrap/kubeconfig (generated after init)
  - /opt/manifests/* (service manifests)
  - /opt/helm-values/* (Helm configurations)
  - /var/log/bootstrap.log (bootstrap output)

Nodes 2/3:
  - /opt/bootstrap/node-join.sh (join script)
  - /var/log/bootstrap.log (bootstrap output)

################################################################################
EOF

    log_info "Cluster info saved to $output_dir/cluster-info.txt"

    # Set proper permissions
    chmod 600 "$output_dir"/*.txt 2>/dev/null || true
    chmod 644 "$output_dir/cluster-info.txt"

    log_info "All credentials generated successfully"
}

################################################################################
# Main function for standalone execution
################################################################################

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Script is being run directly
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_directory>"
        exit 1
    fi

    generate_all_credentials "$1"
fi
