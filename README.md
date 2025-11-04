# OSBuild - Raspberry Pi 5 OS Image Builder

Automated OS image building and deployment system for Raspberry Pi 5 Kubernetes clusters.

## Overview

OSBuild provides a Docker-based build system for creating bootable Raspberry Pi 5 images with Kubernetes pre-installed.

**Current Focus**: SD card boot images (netboot planned for future phase)

Key features:
- Docker-based build - only requires Docker, no other dependencies
- Builds bootable .img files for SD cards
- Kubernetes 1.28.0 pre-installed (containerd, kubeadm, kubelet, kubectl)
- Zero manual configuration - fully automated setup
- Generic images with first-boot auto-provisioning
- Bootstrap scripts pulled from git for version control
- Automatic Kubernetes cluster joining
- Comprehensive verification and testing tools

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Docker Build (Pure Docker - No dependencies!)          │
│  ├─ Download Raspberry Pi OS Lite ARM64                 │
│  ├─ Expand image with QEMU ARM64 emulation             │
│  ├─ Install Kubernetes 1.28.0                           │
│  ├─ Install bootstrap framework                         │
│  ├─ Configure first-boot auto-provisioning              │
│  ├─ Shrink and optimize image                           │
│  └─ Output: bootable .img file for SD card              │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│  Flash to SD Card                                        │
│  - Use dd command or Raspberry Pi Imager                │
│  - Boot Raspberry Pi 5 from SD card                     │
│  - First-boot service auto-provisions node              │
│  - Joins Kubernetes cluster automatically               │
└─────────────────────────────────────────────────────────┘
```

## How It Works

### Image Build Process

1. **Download Base**: Raspberry Pi OS Lite ARM64 (Bookworm)
2. **Expand Image**: Add 2GB space for Kubernetes components
3. **Install Kubernetes**: containerd 1.6.20, kubeadm/kubelet/kubectl 1.28.0, CNI plugins v1.4.0, crictl v1.28.0
4. **Install Bootstrap**: First-boot systemd service + bootstrap framework
5. **Configure System**: SSH keys-only, cgroups enabled, swap disabled, timezone UTC
6. **Shrink & Optimize**: Minimize image size, align to 512-byte sectors
7. **Output**: Bootable .img file (~ 3.9GB compressed)

### First Boot Flow

```
Power On → Boot from SD Card
    ↓
First-boot service runs
    ↓
Detect if already provisioned (check /var/lib/bootstrap-complete)
    ↓ (if not provisioned)
Fetch bootstrap scripts from git (https://github.com/altyrus/k8s-bootstrap.git)
    ↓
Execute setup.sh (configure hostname, networking, SSH keys)
    ↓
Join Kubernetes cluster (kubeadm join)
    ↓
Mark as provisioned (/var/lib/bootstrap-complete)
    ↓
Remove first-boot marker (/etc/first-boot-marker)
```

### Node Identity

Nodes are identified by:
- MAC address (primary)
- Serial number (fallback)
- Configuration stored in `bootstrap-repo/config/nodes.yaml`

## Project Structure

```
osbuild/
├── Dockerfile                       # Docker build environment
├── .dockerignore                    # Docker build exclusions
├── docker-build-simple.sh           # Main build script (Docker-based)
├── .github/
│   └── workflows/
│       └── build-image.yml          # GitHub Actions CI/CD pipeline (TODO)
├── image-build/
│   ├── scripts/                     # Build scripts (run inside Docker)
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
│   ├── docker-entrypoint.sh         # Docker container entry point
│   ├── shrink-image.sh              # Shrink image to minimum size
│   ├── extract-rootfs.sh            # Extract rootfs from image
│   ├── verify-image.sh              # Verify image contents
│   └── docker-verify.sh             # Run verification in Docker
├── output/                          # Build outputs (gitignored)
└── test-output/                     # Test build outputs (gitignored)
```

## Quick Start

### Prerequisites

- Docker installed and running
- 10GB+ free disk space
- Linux/macOS host (Windows with WSL2 should work)

### Building an Image

**Build with Docker** (Only requirement: Docker):
```bash
git clone https://github.com/altyrus/osbuild.git
cd osbuild
./docker-build-simple.sh

# Custom output location
./docker-build-simple.sh ./my-output

# Different Kubernetes version
./docker-build-simple.sh ./output 1.29.0
```

Build takes 15-30 minutes and produces:
- `rpi5-k8s-VERSION.img` - Bootable disk image (~3.9GB)
- `rpi5-k8s-VERSION.img.sha256` - Checksum for verification
- `metadata.json` - Build information

### Verifying the Image

```bash
# Verify image contents
./scripts/docker-verify.sh ./output/rpi5-k8s-*.img
```

Checks for:
- Kubernetes binaries installed correctly
- Systemd services enabled
- Boot configuration (cgroups, etc.)
- SSH configuration
- Bootstrap framework installed

### Flashing to SD Card

1. Build image locally using Docker (see above) or download from releases
2. Flash to SD card:
   ```bash
   # Using dd (Linux/macOS)
   sudo dd if=output/rpi5-k8s-VERSION.img of=/dev/sdX bs=4M status=progress conv=fsync

   # Or use Raspberry Pi Imager
   # Select "Use custom" and choose the .img file
   ```
3. Insert SD card into Raspberry Pi 5
4. Power on - node auto-provisions and joins cluster on first boot

## Requirements

### Build Environment
- Docker installed and running
- 10GB+ free disk space
- Linux/macOS host (Windows with WSL2 should work)

### Runtime
- Raspberry Pi 5
- SD card (16GB+ recommended)
- Network connectivity for first-boot provisioning

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

### Docker-Based Build
- Single dependency (Docker only)
- Works on any Docker-enabled host
- No host system pollution
- Reproducible builds
- Easy CI/CD integration

### Automated Provisioning
- Zero touch first-boot setup
- Consistent, repeatable deployments
- Version controlled configuration (git-based)
- Automatic cluster joining
- No manual SSH configuration needed

## Implementation Status

- [x] **Phase 1: Build System** ✓ COMPLETED
  - [x] Docker-based build environment (pure Docker, no other dependencies)
  - [x] Automated image building with Kubernetes 1.28.0 pre-installed
  - [x] Bootstrap framework with first-boot systemd service
  - [x] Image shrinking and optimization
  - [x] Comprehensive verification script
  - [x] Helper scripts for Docker-based verification
  - [x] Sector alignment fixes for image compatibility
- [ ] **Phase 2: Testing & Validation**
  - [x] Static image verification (Docker-based)
  - [ ] QEMU boot testing (pending)
  - [ ] Physical Raspberry Pi 5 hardware testing (pending)
- [ ] **Phase 3: Bootstrap Script Development**
  - [ ] Create k8s-bootstrap repository
  - [ ] Node inventory management (nodes.yaml)
  - [ ] Kubernetes init/join scripts
  - [ ] End-to-end provisioning testing
- [ ] **Phase 4: Production Deployment**
  - [ ] Flash and test on physical hardware
  - [ ] SD card deployment procedures
  - [ ] Performance validation
  - [ ] Documentation and runbooks

## Contributing

See [claude.md](claude.md) for detailed planning and architecture discussions.

## License

MIT
