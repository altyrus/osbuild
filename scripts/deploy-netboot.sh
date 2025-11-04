#!/bin/bash
#
# deploy-netboot.sh - Deploy rootfs to netboot server
#
# This script deploys the extracted rootfs tarball to an NFS server
# for netboot deployment. It handles extraction, deployment, and
# ensures atomic updates.
#
# Usage: ./deploy-netboot.sh <rootfs.tar.gz> <server> [ssh_key]
#

set -euo pipefail

ROOTFS_TAR="${1:?Rootfs tarball required}"
NETBOOT_SERVER="${2:?Netboot server required}"
SSH_KEY="${3:-}"

if [[ ! -f "$ROOTFS_TAR" ]]; then
    echo "ERROR: Rootfs tarball not found: $ROOTFS_TAR"
    exit 1
fi

echo "=========================================="
echo "Deploying rootfs to netboot server"
echo "Tarball: $ROOTFS_TAR"
echo "Server: $NETBOOT_SERVER"
echo "=========================================="

# SSH options
SSH_OPTS="-o StrictHostKeyChecking=no"
if [[ -n "$SSH_KEY" ]]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
fi

# Verify checksum if available
if [[ -f "${ROOTFS_TAR}.sha256" ]]; then
    echo "Verifying checksum..."
    sha256sum -c "${ROOTFS_TAR}.sha256" || {
        echo "ERROR: Checksum verification failed"
        exit 1
    }
fi

# Configuration
REMOTE_NFS_ROOT="/srv/netboot/rpi5"
REMOTE_WORK_DIR="/tmp/netboot-deploy-$$"
VERSION=$(date +%Y%m%d-%H%M%S)

echo "Uploading tarball to server..."
ssh $SSH_OPTS "$NETBOOT_SERVER" "mkdir -p $REMOTE_WORK_DIR"
scp $SSH_OPTS "$ROOTFS_TAR" "${NETBOOT_SERVER}:${REMOTE_WORK_DIR}/rootfs.tar.gz"

echo "Extracting on remote server..."
ssh $SSH_OPTS "$NETBOOT_SERVER" <<EOF
set -euo pipefail

echo "Creating extraction directory..."
mkdir -p ${REMOTE_WORK_DIR}/rootfs

echo "Extracting tarball..."
cd ${REMOTE_WORK_DIR}/rootfs
tar -xzf ${REMOTE_WORK_DIR}/rootfs.tar.gz

echo "Setting permissions..."
chmod 755 .

echo "Creating version marker..."
cat > etc/netboot-version <<VERSION_EOF
{
    "version": "${VERSION}",
    "deployed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "deployed_by": "$(whoami)@$(hostname)"
}
VERSION_EOF

echo "Preparing deployment..."
sudo mkdir -p ${REMOTE_NFS_ROOT}

# Atomic deployment using symlink swap
echo "Creating new deployment..."
sudo rm -rf ${REMOTE_NFS_ROOT}/new
sudo mv ${REMOTE_WORK_DIR}/rootfs ${REMOTE_NFS_ROOT}/new

# Create backup of current
if [[ -L ${REMOTE_NFS_ROOT}/current ]]; then
    echo "Backing up current deployment..."
    sudo rm -rf ${REMOTE_NFS_ROOT}/previous
    CURRENT_TARGET=\$(readlink ${REMOTE_NFS_ROOT}/current)
    if [[ -d "\$CURRENT_TARGET" ]]; then
        sudo mv "\$CURRENT_TARGET" ${REMOTE_NFS_ROOT}/previous
    fi
fi

# Atomic swap
echo "Activating new deployment..."
sudo rm -f ${REMOTE_NFS_ROOT}/current
sudo ln -s ${REMOTE_NFS_ROOT}/new ${REMOTE_NFS_ROOT}/current

# Rename new to version
sudo mv ${REMOTE_NFS_ROOT}/new ${REMOTE_NFS_ROOT}/${VERSION}
sudo ln -sf ${REMOTE_NFS_ROOT}/${VERSION} ${REMOTE_NFS_ROOT}/current

echo "Cleaning up..."
rm -rf ${REMOTE_WORK_DIR}

echo "Deployment completed successfully"
echo "Current version: ${VERSION}"
echo "Location: ${REMOTE_NFS_ROOT}/current -> ${REMOTE_NFS_ROOT}/${VERSION}"
EOF

echo "=========================================="
echo "Deployment completed successfully"
echo "Version: $VERSION"
echo "Server: $NETBOOT_SERVER"
echo "Path: ${REMOTE_NFS_ROOT}/current"
echo "=========================================="
echo ""
echo "To rollback to previous version:"
echo "  ssh ${NETBOOT_SERVER} 'sudo ln -sf ${REMOTE_NFS_ROOT}/previous ${REMOTE_NFS_ROOT}/current'"
echo ""
echo "To list versions:"
echo "  ssh ${NETBOOT_SERVER} 'ls -lh ${REMOTE_NFS_ROOT}/'"
