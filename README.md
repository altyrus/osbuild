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
├── image-build/              # Packer/pi-gen configurations
│   ├── packer/
│   ├── scripts/
│   └── files/
├── bootstrap/                # Bootstrap scripts (can be separate repo)
│   ├── setup.sh
│   ├── config/
│   ├── scripts/
│   └── manifests/
├── netboot/                  # Netboot server configuration
│   ├── dnsmasq.conf
│   └── nfs-exports
├── .github/
│   └── workflows/
│       └── build-image.yml
└── docs/
```

## Quick Start

### Development (Netboot)

1. Build image via CI/CD
2. Deploy rootfs to NFS server
3. Configure netboot server (dnsmasq + NFS)
4. Boot Raspberry Pi 5 from network
5. Node auto-provisions and joins cluster

### Production (NVMe)

1. Download built image from releases
2. Flash to NVMe: `dd if=disk.img of=/dev/nvme0n1 bs=4M status=progress`
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

## Roadmap

- [ ] Phase 1: CI/CD pipeline for image building
- [ ] Phase 2: Netboot dev environment setup
- [ ] Phase 3: Bootstrap script development
- [ ] Phase 4: NVMe production validation
- [ ] Phase 5: Operational procedures and monitoring

## Contributing

See [claude.md](claude.md) for detailed planning and architecture discussions.

## License

MIT
