# OSBuild - Planning and Architecture Documentation

This document contains the detailed planning, architectural decisions, and technical discussions for the OSBuild project.

## Project Goals

Build OS images for Raspberry Pi 5 that enable:
1. Fully automated installation and setup
2. Cloud-init or similar for first-boot automation
3. Support for both diskless netboot and NVMe-based deployments
4. Zero manual configuration steps
5. CI/CD automated image building
6. Automatic Kubernetes cluster joining

## Architectural Decision: Hybrid Approach

After analysis, we chose a hybrid approach:
- **Development/Testing**: Netboot (diskless)
- **Production**: NVMe storage

### Why Hybrid?

**Netboot for Development:**
- Fast iteration - change image, reboot, done
- No physical media to manage
- True stateless nodes
- Easy to test changes
- Centralized image management

**NVMe for Production:**
- More reliable than SD cards
- No network dependency for boot
- Better performance
- Standard deployment method
- Easier initial setup for production

**Single Build Pipeline:**
- One image build process
- Outputs both netboot rootfs and NVMe disk image
- Test exact same image in dev before production deployment

## Deep Analysis: Netboot vs SD Cards vs NVMe

### SD Card Reality Check

**Initial assessment was too optimistic about SD cards. Reality:**

- SD card failures are frequent, not occasional
- Each failure requires physical intervention
- With 20+ nodes, it's a constant maintenance burden
- Updates require reflashing or dealing with configuration drift
- Fighting hardware entropy constantly

**Operational burden:**
- Node fails at 2 AM → Drive to location → Pull card → Flash new → Insert → Boot
- Security patch → Build image → Flash 20+ cards (or update in-place and risk drift)
- Over time, nodes become unique snowflakes unless you're religious about rebuilds

### Netboot Advantages

**Operational reality:**
- Node fails → Power cycle → Boots fresh from network
- Image corrupted? Fix once on server, all nodes get it next boot
- No physical media to wear out
- Every boot is fresh - zero configuration drift possible
- Security update → Update one image → Reboot nodes → Done

**For Kubernetes specifically:**
- K8s already assumes nodes are replaceable
- Stateless workload philosophy
- Distributed storage handled separately (etcd, PVs)
- Node replacement is normal operations
- SD cards add unwanted state at node level

**Key insight about network dependency:**
- In a K8s cluster, if network is down, cluster is non-functional anyway
- Workloads depend on network
- etcd needs network
- Pod networking needs network
- Storage networking needs network
- Netboot's network dependency is NOT a new failure mode

### NVMe for Production

**Why NVMe over SD cards:**
- Much more reliable than SD cards
- Better performance
- No wear issues like SD cards
- Still allows local boot (network not required after provisioning)
- Industry standard for persistent storage

**Why NVMe over netboot for production:**
- Reduces operational complexity (fewer moving parts)
- Can boot without network (useful for troubleshooting)
- Proven deployment method
- Easier to explain to stakeholders

## Architecture Design

### Single Image Build Pipeline

```
CI/CD Pipeline (GitHub Actions/GitLab CI)
    ↓
┌─────────────────────────────────────────┐
│  Stage 1: Base OS Build                 │
│  - Raspberry Pi OS Lite 64-bit          │
│  - Kernel updates                       │
│  - Essential packages                   │
│  - Remove bloat                         │
│  Tool: Packer + QEMU or pi-gen          │
└─────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────┐
│  Stage 2: Bootstrap Layer               │
│  - Install: curl, git, jq, cloud-init   │
│  - Add: /opt/bootstrap/bootstrap.sh     │
│  - Add: systemd first-boot.service      │
│  - State tracking: /var/lib/provisioned │
└─────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────┐
│  Stage 3: K8s Prerequisites             │
│  - containerd / cri-o                   │
│  - kubeadm, kubelet, kubectl            │
│  - CNI plugins                          │
│  - Disable swap                         │
│  - Enable cgroups                       │
│  - Kernel modules (overlay, etc)        │
└─────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────┐
│  Stage 4: Output Artifacts              │
│  - rootfs.tar.gz (for netboot NFS)      │
│  - disk.img (for NVMe flashing)         │
│  - checksums + metadata.json            │
└─────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────┐
│  Stage 5: Distribution                  │
│  - Upload to artifact registry          │
│  - Deploy rootfs to NFS for netboot     │
│  - Publish .img for NVMe flashing       │
└─────────────────────────────────────────┘
```

### First-Boot Detection & Automation

**Critical requirement:** Detect first boot reliably on both netboot and NVMe

**Multi-layered state detection approach:**

```bash
is_first_boot() {
    # 1. Check provisioning state file
    if [[ -f /var/lib/node-provisioned ]]; then
        return 1  # Already provisioned
    fi

    # 2. Check if kubelet is running
    if systemctl is-active --quiet kubelet; then
        return 1  # Already provisioned
    fi

    # 3. Check if node is in cluster
    if kubectl get node "$(hostname)" 2>/dev/null; then
        return 1  # Already in cluster
    fi

    return 0  # This is first boot
}
```

**Bootstrap process:**

1. First-boot systemd service runs on every boot
2. Checks if already provisioned (multi-factor detection)
3. If not provisioned:
   - Determine node identity (MAC address, serial number)
   - Query bootstrap server or nodes.yaml for configuration
   - Fetch latest bootstrap scripts from git repository
   - Execute setup scripts with retry logic
   - Join Kubernetes cluster
   - Mark as provisioned
4. If already provisioned: exit immediately

### Bootstrap Script Architecture

**Separation of concerns:**
- **OS Image** = Infrastructure layer (changes slowly)
  - Base OS, kernel, packages
  - Bootstrap framework
  - K8s binaries

- **Bootstrap Scripts** = Configuration layer (changes frequently)
  - Node identity and roles
  - Network configuration
  - Cluster joining logic
  - Application deployment

**Repository structure:**

```
k8s-bootstrap-repo/
├── setup.sh                    # Main entry point
├── config/
│   ├── nodes.yaml             # Node inventory (MAC → config)
│   ├── cluster-config.yaml    # Cluster-wide settings
│   └── environments/
│       ├── dev.yaml
│       └── prod.yaml
├── scripts/
│   ├── 00-system-prep.sh      # Hostname, networking
│   ├── 01-storage-setup.sh    # Persistent volumes
│   ├── 02-k8s-init.sh         # kubeadm init/join
│   ├── 03-cni-install.sh      # Network plugin
│   ├── 04-apps-deploy.sh      # Applications
│   └── utils.sh               # Shared functions
├── manifests/
│   ├── core/                  # Essential manifests
│   └── apps/                  # Applications
└── tests/
    └── verify-node.sh         # Post-bootstrap validation
```

### Node Identity Management

**Three approaches evaluated:**

1. **MAC-based (recommended for start)**
   - Pre-configure nodes.yaml with MAC addresses
   - Simple, deterministic
   - Requires knowing MACs in advance
   - Works great for static deployments

2. **API-based registration (for scaling)**
   - Node boots, calls API with MAC/Serial
   - API returns config or registers new node
   - More flexible, better for dynamic scaling
   - Requires additional infrastructure

3. **Hybrid (best of both)**
   - Try nodes.yaml first
   - Fall back to API for unknown nodes
   - Allows both planned and dynamic nodes

**Node configuration example:**

```yaml
nodes:
  - mac: "dc:a6:32:12:34:56"
    hostname: "k8s-master-01"
    role: "control-plane"
    ip: "10.0.10.10"

  - mac: "dc:a6:32:12:34:57"
    hostname: "k8s-worker-01"
    role: "worker"
    ip: "10.0.10.11"

default:
  role: "worker"
  hostname_prefix: "k8s-node-"
  auto_register: true
```

## Complete Workflows

### Development: Netboot Flow

```
1. Developer commits code changes
2. CI/CD builds new image automatically
3. Rootfs deployed to NFS server
4. Reboot test Pi (or automatic reboot)
5. Pi netboots, gets fresh image
6. First-boot service runs → detects not provisioned
7. Fetches latest bootstrap scripts from git
8. Executes setup.sh → joins cluster
9. Testing complete in <10 minutes
```

### Production: NVMe Flow

```
1. CI/CD builds and tags release
2. disk.img published to GitHub releases
3. Download and verify checksums
4. Flash to NVMe drives (dd or Raspberry Pi Imager)
5. Insert NVMe into Pi, power on
6. First-boot service runs → detects not provisioned
7. Fetches latest bootstrap scripts from git
8. Executes setup.sh → joins cluster
9. Production node operational
```

## Technical Implementation Details

### Systemd First-Boot Service

```ini
[Unit]
Description=First Boot Node Provisioning
After=network-online.target
Wants=network-online.target
Before=kubelet.service
ConditionPathExists=!/var/lib/node-provisioned

[Service]
Type=oneshot
ExecStart=/opt/bootstrap/bootstrap.sh
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=600
ReadWritePaths=/var/lib

[Install]
WantedBy=multi-user.target
```

### Bootstrap Script Flow

```bash
#!/bin/bash
# /opt/bootstrap/bootstrap.sh (baked into image)

set -euo pipefail

STATE_FILE="/var/lib/node-provisioned"
CONFIG_ENDPOINT="https://bootstrap.yourdomain.com/config"
SCRIPT_REPO="https://github.com/yourorg/k8s-bootstrap.git"

# Multi-factor first-boot detection
is_first_boot() {
    [[ ! -f "$STATE_FILE" ]] && \
    ! systemctl is-active --quiet kubelet && \
    ! kubectl get node "$(hostname)" 2>/dev/null
}

# Determine node identity
get_node_identity() {
    MAC=$(cat /sys/class/net/eth0/address | tr -d ':')
    SERIAL=$(cat /proc/cpuinfo | grep Serial | cut -d ' ' -f 2)
    curl -sf "${CONFIG_ENDPOINT}?mac=${MAC}&serial=${SERIAL}" || echo "{}"
}

# Fetch latest bootstrap scripts
fetch_bootstrap_scripts() {
    TEMP_DIR=$(mktemp -d)
    git clone --depth 1 "$SCRIPT_REPO" "$TEMP_DIR/bootstrap"
    echo "$TEMP_DIR/bootstrap"
}

main() {
    if ! is_first_boot; then
        echo "Node already provisioned, skipping"
        exit 0
    fi

    echo "First boot detected - starting provisioning"

    NODE_CONFIG=$(get_node_identity)
    export NODE_CONFIG

    BOOTSTRAP_DIR=$(fetch_bootstrap_scripts)

    # Execute with retry
    for attempt in {1..3}; do
        if "${BOOTSTRAP_DIR}/setup.sh"; then
            date > "$STATE_FILE"
            echo "$NODE_CONFIG" >> "$STATE_FILE"
            exit 0
        fi
        sleep 10
    done

    echo "Bootstrap failed after 3 attempts"
    exit 1
}

main "$@"
```

### Handling Netboot vs NVMe Differences

**Boot mode detection:**

```bash
get_boot_mode() {
    if grep -q "nfsroot" /proc/cmdline; then
        echo "netboot"
    elif [[ -b /dev/nvme0n1 ]]; then
        echo "nvme"
    else
        echo "unknown"
    fi
}

get_persistence_path() {
    case "$(get_boot_mode)" in
        netboot)
            # Use NFS-backed persistent storage
            echo "/var/lib/persistent"
            ;;
        nvme)
            # Use local storage
            echo "/var/lib"
            ;;
        *)
            echo "/tmp/fallback"
            ;;
    esac
}
```

**Persistent data requirements:**

For netboot:
- etcd: Separate NFS export or dedicated storage
- kubelet state: `/var/lib/kubelet` must persist
- Container storage: Use distributed storage (Longhorn, Rook)
- Logs: Remote logging or memory-based with archival

For NVMe:
- All persistent data on local NVMe
- Consider partition layout (boot + root + data)
- Auto-expand root filesystem on first boot

### CI/CD Pipeline

**GitHub Actions workflow:**

```yaml
name: Build Raspberry Pi OS Image

on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      kubernetes_version:
        description: 'Kubernetes version'
        required: true
        default: '1.28.0'

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
    - name: Checkout code
      uses: actions/checkout@v4

    - name: Set up QEMU ARM64
      uses: docker/setup-qemu-action@v3
      with:
        platforms: arm64

    - name: Install dependencies
      run: |
        sudo apt-get update
        sudo apt-get install -y qemu-user-static debootstrap kpartx

    - name: Build image with Packer
      run: |
        cd image-build
        packer init .
        packer build \
          -var "k8s_version=${{ env.K8S_VERSION }}" \
          -var "image_version=${{ github.sha }}" \
          raspberry-pi.pkr.hcl

    - name: Extract rootfs for netboot
      run: |
        ./scripts/extract-rootfs.sh \
          output/disk.img \
          output/netboot/rootfs.tar.gz

    - name: Generate checksums
      run: |
        cd output
        sha256sum disk.img > disk.img.sha256
        sha256sum netboot/rootfs.tar.gz > netboot/rootfs.tar.gz.sha256

    - name: Deploy to netboot server (dev)
      if: github.ref == 'refs/heads/main'
      run: |
        ./scripts/deploy-netboot.sh \
          output/netboot/rootfs.tar.gz \
          ${{ secrets.NETBOOT_SERVER }}

    - name: Publish release artifacts (prod)
      if: startsWith(github.ref, 'refs/tags/v')
      uses: softprops/action-gh-release@v1
      with:
        files: |
          output/disk.img
          output/disk.img.sha256
          output/metadata.json
```

## Security Considerations

### Bootstrap Script Security

**Verify git signatures:**

```bash
SCRIPT_REPO="https://github.com/yourorg/k8s-bootstrap.git"
GPG_KEY_ID="YOUR_GPG_KEY_ID"

git clone "$SCRIPT_REPO" /tmp/bootstrap
cd /tmp/bootstrap
git verify-commit HEAD || {
    echo "ERROR: Bootstrap script signature verification failed"
    exit 1
}
```

**Alternative: Checksum verification:**

```bash
# Download bootstrap tarball and checksum
curl -O https://bootstrap.example.com/scripts.tar.gz
curl -O https://bootstrap.example.com/scripts.tar.gz.sha256

# Verify checksum
sha256sum -c scripts.tar.gz.sha256 || exit 1

# Extract and execute
tar xzf scripts.tar.gz
./bootstrap/setup.sh
```

### Network Security

- Use HTTPS for bootstrap script downloads
- Implement mutual TLS for node registration API
- Secure TFTP with network isolation (VLAN)
- NFS exports with host restrictions and no_root_squash carefully managed

### Secrets Management

- Never bake secrets into images
- Use Kubernetes secrets or external secret management
- Consider Vault, SOPS, or sealed-secrets
- Bootstrap scripts should fetch secrets securely

## Advantages of This Design

1. **Single Source of Truth**
   - One image build works everywhere
   - No divergence between dev and prod
   - Test exact same artifacts

2. **Zero Manual Configuration**
   - Flash and forget (or netboot and forget)
   - No SSH, no manual steps
   - Fully automated from power-on to cluster-ready

3. **Separation of Concerns**
   - OS image = infrastructure (stable)
   - Bootstrap scripts = configuration (dynamic)
   - Independent update cycles

4. **Easy Updates**
   - Scripts: Commit to git, reboot nodes
   - OS: Build new image, deploy
   - No configuration drift possible

5. **Testable**
   - Test in netboot first
   - Validate before production
   - Quick iteration cycles

6. **Auditable**
   - Git history for all changes
   - Build artifacts versioned
   - Know exactly what's deployed

7. **Recoverable**
   - Node dies? Boot another with same identity
   - Image corrupted? Reboot gets fresh copy
   - No data loss (persistent data separate)

8. **Scalable**
   - Add node: Update nodes.yaml + boot
   - No per-node customization
   - Scales to hundreds of nodes

## Implementation Phases

### Phase 1: Foundation (Week 1-2)
- [ ] Set up CI/CD pipeline for image building
- [ ] Create basic Packer/pi-gen build
- [ ] Produce both .img and rootfs outputs
- [ ] Implement first-boot detection service
- [ ] Create minimal bootstrap.sh that pulls from git

### Phase 2: Netboot Dev Environment (Week 2-3)
- [ ] Set up netboot server (dnsmasq + NFS)
- [ ] Deploy built rootfs to NFS
- [ ] Configure 1-2 test Pis for netboot
- [ ] Test first-boot provisioning
- [ ] Iterate until K8s cluster forms automatically

### Phase 3: Bootstrap Scripts (Week 3-4)
- [ ] Build out full bootstrap script suite
- [ ] Add node inventory management (nodes.yaml)
- [ ] Implement K8s init/join logic
- [ ] Integrate existing K8s + app deployment scripts
- [ ] Test complete end-to-end flow

### Phase 4: NVMe Production (Week 4-5)
- [ ] Flash same image to NVMe
- [ ] Test first-boot on NVMe hardware
- [ ] Validate persistent storage behavior
- [ ] Optimize partition layout
- [ ] Deploy to production

### Phase 5: Operations (Ongoing)
- [ ] Monitor bootstrap reliability
- [ ] Build image update procedures
- [ ] Create runbooks for common operations
- [ ] Set up metrics and logging
- [ ] Document troubleshooting

## Troubleshooting

### Common Issues

**First-boot script doesn't run:**
- Check systemd service status: `systemctl status first-boot.service`
- View logs: `journalctl -u first-boot.service`
- Verify network connectivity: `ping 8.8.8.8`
- Check bootstrap endpoint: `curl -v $CONFIG_ENDPOINT`

**Node can't join cluster:**
- Verify kubeadm is installed: `kubeadm version`
- Check kubelet logs: `journalctl -u kubelet`
- Verify network connectivity to control plane
- Check firewall rules (6443, 10250, etc)

**Netboot node won't boot:**
- Verify DHCP offers: `tcpdump -i eth0 port 67`
- Check TFTP server: `tftp $SERVER -c get bootcode.bin`
- Verify NFS export: `showmount -e $NFS_SERVER`
- Check Pi firmware is updated for netboot

**NVMe not detected:**
- Verify NVMe adapter compatibility
- Update Raspberry Pi EEPROM: `sudo rpi-eeprom-update`
- Check for NVMe: `lsblk`
- Verify PCIe is enabled in config.txt

## Future Enhancements

### Short Term
- Add A/B partition scheme for safer updates
- Implement rollback mechanism
- Add pre-flight checks before joining cluster
- Support multiple K8s versions in build pipeline

### Medium Term
- Web UI for node inventory management
- API-based node registration
- Automated testing in netboot environment
- Image build optimization (caching, incremental)

### Long Term
- Support for other SBCs (Rock Pi, Orange Pi)
- Immutable root filesystem with overlayfs
- Integration with GitOps (ArgoCD, Flux)
- Observability and metrics collection

## References

### Tools
- **Packer**: https://www.packer.io/
- **pi-gen**: https://github.com/RPi-Distro/pi-gen
- **cloud-init**: https://cloud-init.io/
- **dnsmasq**: https://thekelleys.org.uk/dnsmasq/doc.html

### Documentation
- Raspberry Pi netboot: https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#network-booting
- Kubernetes kubeadm: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/
- NFS root filesystem: https://wiki.archlinux.org/title/NFS#Root_filesystem

### Inspiration
- Talos Linux: Immutable Kubernetes OS
- Flatcar Linux: Container-optimized OS
- NixOS: Declarative system configuration

## Project Setup Status

### Environment Configuration
- **Project Location**: `/POOL01/software/projects/osbuild`
- **GitHub Repository**: https://github.com/altyrus/osbuild
- **Owner**: altyrus (Scot Gray - scot.gray@altyrus.com)
- **Git Branch**: main

### Completed Setup Tasks
- ✅ Git repository initialized
- ✅ GitHub CLI (`gh`) installed and authenticated
- ✅ Passwordless sudo configured for package installation
- ✅ Initial documentation created (README.md, claude.md, NOTES.md)
- ✅ Repository pushed to GitHub
- ✅ VSCode Claude Code auto-approve settings configured

### Team Collaboration
- **GitHub Access**: Primary development repository
- **Google Drive**: Documentation sharing for team members without GitHub access
  - Manual sync process: Copy `/POOL01/software/projects/osbuild` to Google Drive as needed
  - Provides file structure and documentation access for all team members

### VSCode Claude Code Settings
Location: `C:/Users/scot/AppData/Roaming/Code/User/settings.json`

```json
{
    "claudeCode.autoApprove": true,
    "claudeCode.requireConfirmation": false,
    "claudeCode.planMode": false,
    "claudeCode.autoApproveEdits": true,
    "claudeCode.autoApproveWrites": true,
    "claudeCode.autoApproveDeletes": true
}
```

These settings allow Claude Code to automatically create, modify, and delete files in the project without manual approval for each operation.

## Next Steps

Ready to begin implementation. Choose a starting phase:

1. **Phase 1: CI/CD Pipeline**
   - Set up GitHub Actions workflow structure
   - Configure Packer or pi-gen for ARM64 builds
   - Create base image build scripts

2. **Phase 2: Bootstrap Framework**
   - Develop first-boot detection service
   - Create bootstrap.sh script framework
   - Set up systemd service configuration

3. **Phase 3: Netboot Server**
   - Configure dnsmasq for DHCP/TFTP
   - Set up NFS server exports
   - Create netboot deployment scripts

4. **Phase 4: Node Inventory**
   - Create nodes.yaml configuration schema
   - Develop node identity detection
   - Build configuration management system

## Conclusion

This hybrid approach provides:
- **Fast development** with netboot
- **Reliable production** with NVMe
- **Zero touch provisioning** for both
- **Single build pipeline** for consistency
- **Fully automated** from power-on to cluster-ready

The key insight: Don't fight the Kubernetes philosophy of ephemeral nodes. Embrace it with stateless OS images and externalized configuration.

---

**Document Status**: Updated 2025-11-03 with project setup completion and team collaboration details.
