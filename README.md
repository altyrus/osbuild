# OSBuild - Raspberry Pi 5 OS Image Builder

Automated OS image building and deployment system for Raspberry Pi 5 Kubernetes clusters.

## Overview

OSBuild provides a hybrid approach to deploying Raspberry Pi 5 nodes:
- **Development**: Diskless netboot for fast iteration
- **Production**: NVMe-based images for reliability

Key features:
- Single CI/CD pipeline produces both netboot and NVMe images
- Zero manual configuration - fully automated setup
- Generic images with first-boot auto-provisioning
- Bootstrap scripts pulled from git for version control
- Automatic Kubernetes cluster joining

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  CI/CD Pipeline (GitHub Actions)                        │
│  ├─ Build base OS image                                 │
│  ├─ Install K8s prerequisites                           │
│  ├─ Add bootstrap layer                                 │
│  └─ Output: rootfs.tar.gz + disk.img                    │
└─────────────────────────────────────────────────────────┘
                        ↓
        ┌───────────────┴───────────────┐
        ↓                               ↓
┌───────────────┐              ┌────────────────┐
│  Development  │              │   Production   │
│   (Netboot)   │              │    (NVMe)      │
│               │              │                │
│ - NFS server  │              │ - Flash image  │
│ - Fast boot   │              │ - Persistent   │
│ - Quick test  │              │ - Reliable     │
└───────────────┘              └────────────────┘
```

## How It Works

### Image Build Process

1. **Base OS Layer**: Raspberry Pi OS Lite (64-bit) with kernel updates
2. **Bootstrap Layer**: First-boot service + bootstrap script
3. **K8s Prerequisites**: containerd, kubeadm, kubelet, CNI plugins
4. **Output**: Generic image ready for both netboot and NVMe

### First Boot Flow

```
Power On
    ↓
Boot (netboot or NVMe)
    ↓
First-boot service runs
    ↓
Detect if already provisioned
    ↓ (if not provisioned)
Fetch bootstrap scripts from git
    ↓
Execute setup.sh
    ↓
Join Kubernetes cluster
    ↓
Mark as provisioned
```

### Node Identity

Nodes are identified by:
- MAC address (primary)
- Serial number (fallback)
- Configuration stored in `bootstrap-repo/config/nodes.yaml`

## Project Structure

```
osbuild/
├── .github/
│   └── workflows/
│       └── build-image.yml          # GitHub Actions CI/CD pipeline
├── image-build/
│   ├── scripts/                     # Build scripts (run in CI)
│   │   ├── 01-install-k8s.sh       # Install Kubernetes components
│   │   ├── 02-install-bootstrap.sh  # Install bootstrap framework
│   │   ├── 03-configure-firstboot.sh # Configure first-boot
│   │   └── 04-cleanup.sh            # Optimize image
│   ├── files/                       # Files embedded in image
│   │   ├── bootstrap/
│   │   │   └── bootstrap.sh         # First-boot provisioning script
│   │   └── systemd/
│   │       └── first-boot.service   # Systemd service
│   ├── cache/                       # Downloaded images (gitignored)
│   └── work/                        # Build workspace (gitignored)
├── scripts/                         # Helper scripts
│   ├── extract-rootfs.sh            # Extract rootfs from image
│   ├── shrink-image.sh              # Shrink image to minimum size
│   ├── deploy-netboot.sh            # Deploy to netboot server
│   └── build-local.sh               # Local build for testing
├── output/                          # Build outputs (gitignored)
├── netboot/                         # Netboot server configuration (future)
└── docs/                            # Documentation (future)
```

## Quick Start

### Building Images

**Automated (GitHub Actions):**
- Push to `main` branch triggers automatic build
- Tag with `v*` creates a release with artifacts
- Artifacts: disk.img, rootfs.tar.gz, checksums

**Local Build:**
```bash
./scripts/build-local.sh [kubernetes_version]
```

**Download Built Images:**
```bash
# Download latest build from GitHub Actions
./scripts/download-artifacts.sh

# Download from releases
gh release download v0.1.0
```

See [Storage Setup Guide](docs/STORAGE_SETUP.md) for Google Drive integration and storage options.

### Development (Netboot)

1. Build image via CI/CD or locally
2. Deploy rootfs to NFS server:
   ```bash
   ./scripts/deploy-netboot.sh output/netboot/rootfs.tar.gz YOUR_SERVER
   ```
3. Configure netboot server (dnsmasq + NFS) - see Phase 2
4. Boot Raspberry Pi 5 from network
5. Node auto-provisions and joins cluster

### Production (NVMe)

1. Download built image from releases or build locally
2. Flash to NVMe:
   ```bash
   sudo dd if=rpi5-k8s-VERSION.img of=/dev/nvme0n1 bs=4M status=progress conv=fsync
   ```
3. Insert NVMe into Raspberry Pi 5
4. Power on - node auto-provisions and joins cluster

## Requirements

### Build Environment
- Linux host with QEMU ARM64 support
- Packer or pi-gen
- Git, curl, basic build tools

### Runtime (Netboot)
- DHCP/TFTP server (dnsmasq)
- NFS server
- Network infrastructure

### Runtime (NVMe)
- Raspberry Pi 5
- NVMe drive (M.2 with appropriate adapter)
- Network connectivity for bootstrap

## Configuration

Node configuration is managed in the bootstrap repository:

```yaml
# config/nodes.yaml
nodes:
  - mac: "dc:a6:32:12:34:56"
    hostname: "k8s-master-01"
    role: "control-plane"
    ip: "10.0.10.10"

  - mac: "dc:a6:32:12:34:57"
    hostname: "k8s-worker-01"
    role: "worker"
    ip: "10.0.10.11"
```

## Benefits

### vs SD Cards
- No SD card wear/failure
- Centralized image management
- Easy updates (reboot vs reflash)

### vs Manual Configuration
- Zero touch provisioning
- Consistent deployments
- Version controlled configuration

### Hybrid Approach
- Test in netboot dev environment
- Deploy same image to NVMe for production
- Single build pipeline for both

## Implementation Status

- [x] **Phase 1: CI/CD Pipeline** ✓ COMPLETED
  - [x] GitHub Actions workflow for automated builds
  - [x] Build scripts for image customization
  - [x] Bootstrap framework with first-boot service
  - [x] Helper scripts for extraction and deployment
  - [x] Local build support for testing
- [ ] **Phase 2: Netboot Dev Environment**
  - [ ] Netboot server configuration (dnsmasq + NFS)
  - [ ] Deployment automation
  - [ ] Testing with physical Raspberry Pi 5 nodes
- [ ] **Phase 3: Bootstrap Script Development**
  - [ ] Create k8s-bootstrap repository
  - [ ] Node inventory management (nodes.yaml)
  - [ ] Kubernetes init/join scripts
  - [ ] End-to-end provisioning
- [ ] **Phase 4: NVMe Production Validation**
  - [ ] Flash and test on NVMe hardware
  - [ ] Production deployment procedures
  - [ ] Performance validation
- [ ] **Phase 5: Operations**
  - [ ] Monitoring and metrics
  - [ ] Update procedures
  - [ ] Runbooks and documentation

## Contributing

See [claude.md](claude.md) for detailed planning and architecture discussions.

## License

MIT
