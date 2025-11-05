# OSBuild - Kubernetes Node Image Builder

Automated build system for creating production-ready Kubernetes node images for x64 (KVM) and Raspberry Pi 5 hardware.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [System Requirements](#system-requirements)
- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [Build Configurations](#build-configurations)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [Integration with Platform Project](#integration-with-platform-project)

## Overview

OSBuild creates customized Debian 13 (Trixie) images with Kubernetes 1.28.0 pre-installed and configured, ready for deployment in HA cluster environments. The images use cloud-init for automated provisioning and are optimized for the [Platform Project](../platform) Kubernetes deployment system.

### Supported Platforms

- **x64/amd64**: For KVM/QEMU virtualization (tested on this host)
- **Raspberry Pi 5**: For bare-metal ARM64 hardware deployment

## Features

### Core Features

- **Debian 13 (Trixie)**: Latest stable Debian base with Linux 6.12 LTS kernel
- **Kubernetes 1.28.0**: Pre-installed kubeadm, kubelet, kubectl
- **Containerd Runtime**: Container runtime with SystemdCgroup enabled
- **Cloud-Init**: Automated provisioning with NoCloud datasource
- **Network Ready**: Virtio networking (x64) or native networking (Pi5)
- **Kubernetes Optimized**: Swap disabled, kernel modules and sysctl pre-configured

### Build Features

- **Shared Libraries**: Common functions for consistent builds across platforms
- **Resilient Downloads**: Retry logic with exponential backoff for network issues
- **Error Handling**: Comprehensive error checking and recovery
- **Image Verification**: Automated verification of installed packages
- **Checksums**: SHA-256 checksums for build verification

## System Requirements

### Build Host

- **OS**: Ubuntu 22.04+ or Debian 12+ (Linux 5.15+)
- **CPU**: x86_64 with KVM support
- **RAM**: Minimum 4GB, recommended 8GB+
- **Disk**: 20GB free space
- **Network**: Stable internet connection for package downloads

### Required Packages (x64 Build)

```bash
sudo apt-get install -y \
    qemu-system-x86-64 \
    qemu-utils \
    kvm \
    losetup \
    parted \
    e2fsprogs \
    coreutils
```

### Required Packages (Pi5 Build)

```bash
sudo apt-get install -y \
    docker.io \
    qemu-user-static \
    binfmt-support \
    kpartx
```

## Quick Start

### Build x64 Image

```bash
cd /POOL01/software/projects/osbuild
sudo ./build-x64.sh
```

**Build time**: ~5-10 minutes (depending on network speed)
**Output**: `output-x64/k8s-x64-<timestamp>.img`

### Build Pi5 Image

```bash
cd /POOL01/software/projects/osbuild
sudo ./docker-build.sh
```

**Build time**: ~15-20 minutes (first build downloads base image)
**Output**: `output/rpi5-k8s-<version>.img`

## Architecture

### Project Structure

```
osbuild/
├── build-x64.sh                 # x64 build script
├── docker-build.sh              # Pi5 Docker build wrapper
├── lib/
│   └── common.sh                # Shared functions
├── config/
│   └── base-images.conf        # Image URLs and versions
├── scripts/
│   ├── docker-entrypoint.sh    # Pi5 Docker build logic
│   └── ...                      # Helper scripts
├── image-build/
│   ├── cache/                   # Downloaded base images
│   └── work-x64/                # x64 build workspace
├── output-x64/                  # x64 built images
└── output/                      # Pi5 built images
```

### Shared Components

#### lib/common.sh

Provides shared functions used by both platforms:

- `setup_chroot()` - Mount proc, sys, dev for chroot operations
- `cleanup_chroot()` - Unmount chroot filesystems
- `chroot_exec()` - Execute commands in chroot environment
- `apt_retry()` - Retry apt operations with backoff
- `disable_swap()` - Disable and mask swap
- `configure_k8s_modules()` - Configure required kernel modules
- `configure_k8s_sysctl()` - Configure sysctl parameters

#### config/base-images.conf

Centralized configuration for:
- Base image URLs (Debian cloud images, Raspberry Pi OS)
- OS versions (Debian 13 Trixie)
- Kubernetes versions (1.28.0)
- Default settings

## Build Configurations

### x64 Configuration

| Component | Version/Setting |
|-----------|----------------|
| **Base OS** | Debian 13 (Trixie) Generic Cloud AMD64 |
| **Kernel** | Linux 6.12 LTS |
| **Kubernetes** | 1.28.0 |
| **Container Runtime** | containerd 1.7.24 |
| **CNI Plugins** | v1.4.0 (optional, can be installed during provisioning) |
| **crictl** | v1.28.0 |
| **Image Size** | 5GB (sparse, ~1.1GB actual) |
| **Filesystem** | ext4 |
| **Boot** | GRUB (cloud image default) |

### Pi5 Configuration

| Component | Version/Setting |
|-----------|----------------|
| **Base OS** | Raspberry Pi OS Lite ARM64 (Trixie) |
| **Release Date** | 2025-10-01 |
| **Kernel** | Linux 6.12 (Pi-optimized) |
| **Kubernetes** | 1.28.0 |
| **Container Runtime** | containerd 1.7.24 |
| **Image Size** | ~4GB |
| **Filesystem** | ext4 |
| **Boot** | Raspberry Pi bootloader |

### Cloud-Init Configuration

Both platforms include embedded cloud-init configuration:

**User Account**:
- Username: `k8s`
- Password: `k8spass` (change after first boot!)
- Groups: sudo, adm, audio, cdrom, dialout, dip, netdev, plugdev, video
- Sudo: Password-less sudo enabled

**Network**:
- DHCP enabled by default
- SSH password authentication enabled
- SSH key authentication supported

**Kubernetes**:
- Swap disabled
- Required kernel modules configured
- Sysctl parameters optimized
- kubelet disabled (enabled during cluster join)

## Testing

### Test x64 Image in KVM

```bash
# Boot image with SSH forwarding to port 2222
sudo qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -nographic \
  -drive file=output-x64/k8s-x64-<timestamp>.img,format=raw,if=virtio \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0
```

**Expected behavior**:
1. GRUB boots automatically (~2s)
2. Kernel loads and initializes (~5s)
3. systemd starts services (~10s)
4. cloud-init executes and completes (~30-60s)
5. Login prompt appears: `k8s-x64-node login:`

**SSH access** (after ~60s):
```bash
ssh k8s@localhost -p 2222
# Password: k8spass
```

**Verification commands**:
```bash
# Check Kubernetes installation
kubectl version --client
kubeadm version
kubelet --version

# Check containerd
sudo systemctl status containerd

# Check cloud-init status
cloud-init status

# Check network
ip addr show
```

### Test Pi5 Image

The Pi5 image must be tested on actual hardware:

1. **Flash to SD card**:
   ```bash
   sudo dd if=output/rpi5-k8s-<version>.img of=/dev/sdX bs=4M status=progress
   sudo sync
   ```

2. **Boot on Pi5 hardware**:
   - Insert SD card into Raspberry Pi 5
   - Connect network cable
   - Power on
   - Wait ~90s for first boot and cloud-init

3. **Find IP and SSH**:
   ```bash
   # Find Pi on network (or check your router/DHCP server)
   nmap -sn 192.168.1.0/24 | grep -B 2 "Raspberry Pi"

   # SSH to Pi
   ssh k8s@<pi-ip-address>
   # Password: k8spass
   ```

## Troubleshooting

### Common Issues

#### Build Fails: "software-properties-common not found"

**Solution**: This package doesn't exist in Debian/Raspberry Pi OS. The x64 build script has been updated to remove this dependency.

#### Build Fails: CNI Plugin Download Error

**Solution**: The build scripts now include retry logic. If CNI plugins fail to download after 3 attempts, the build continues (CNI plugins can be installed during cluster provisioning).

**Manual retry**:
```bash
# Re-run build script - it will use cached base image
sudo ./build-x64.sh
```

#### QEMU Test: "Could not set up host forwarding rule"

**Cause**: Port 2222 already in use
**Solution**:
```bash
# Kill any existing QEMU processes
sudo pkill -f qemu-system-x86_64

# Or use a different port
sudo qemu-system-x86_64 ... -netdev user,id=net0,hostfwd=tcp::2223-:22 ...
```

#### QEMU Test: Pi5 Image Won't Boot

**Cause**: Raspberry Pi kernels don't have virtio drivers in initramfs
**Solution**: Pi5 images can only be tested on actual Pi5 hardware or with specific ARM emulation setup (not recommended).

#### Cloud-Init Doesn't Run

**Check cloud-init logs in the VM**:
```bash
# Inside VM
sudo cloud-init status --long
sudo journalctl -u cloud-init
cat /var/log/cloud-init.log
```

**Common causes**:
- Incorrect datasource configuration
- Network not available during cloud-init execution
- Malformed user-data or meta-data

### Build Script Debugging

Enable verbose output:
```bash
# Add to build script or run with:
bash -x ./build-x64.sh 2>&1 | tee build-debug.log
```

Check specific sections:
```bash
# Check downloaded base image
ls -lh image-build/cache/

# Check loop device setup
sudo losetup -a

# Check mounted filesystems
mount | grep x64-root

# Check chroot environment
sudo ls -la /tmp/x64-root/
```

## Integration with Platform Project

These images are designed to work seamlessly with the [Platform Project](../platform) Kubernetes HA cluster deployment system.

### Platform Integration Points

1. **Cloud-Init Compatibility**: Images use NoCloud datasource which can be overridden by platform's cloud-init generator

2. **SSH Configuration**: Default user (`k8s`) and password authentication enabled for platform provisioning scripts

3. **Kubernetes Pre-Installation**: K8s packages pre-installed and held to prevent automatic updates

4. **Network Configuration**: DHCP enabled by default, can be overridden by platform's network configuration

5. **Containerd Configuration**: Pre-configured with SystemdCgroup for Kubernetes compatibility

### Using with Platform

1. **For libvirt/KVM deployment** (x64):
   ```bash
   cd /POOL01/software/projects/platform

   # Copy OSBuild image to platform VMs directory
   cp /POOL01/software/projects/osbuild/output-x64/k8s-x64-*.img vms/base-image.img

   # Platform scripts will:
   # - Clone base image for each node
   # - Generate cloud-init config with platform-specific settings
   # - Boot VMs and provision cluster
   ```

2. **For Pi5 hardware deployment**:
   ```bash
   # Flash OSBuild image to SD cards
   sudo dd if=/POOL01/software/projects/osbuild/output/rpi5-k8s-*.img \
           of=/dev/sdX bs=4M status=progress

   # Platform can then:
   # - SSH to nodes using default credentials
   # - Run initialization scripts
   # - Join nodes to cluster
   ```

### Platform Variables

OSBuild images work with platform `.env` configuration:

```bash
# Platform .env examples
SSH_USER="k8s"                    # Matches OSBuild default user
SSH_PASSWORD="k8spass"            # Matches OSBuild default (change in production!)
K8S_VERSION="1.28.0"              # Matches OSBuild pre-installed version
ALLOW_PASSWORD="yes"               # OSBuild enables SSH password auth
```

## Build Differences: x64 vs Pi5

| Aspect | x64 Build | Pi5 Build |
|--------|-----------|-----------|
| **Base Image Format** | qcow2 → raw | img.xz → img |
| **Partition Tool** | partprobe, direct access | kpartx, mapper devices |
| **Emulation** | Native (x64 host) | QEMU user-mode (ARM64) |
| **Build Environment** | Direct on host | Docker container |
| **Testing** | KVM on build host | Requires Pi5 hardware |
| **Boot Loader** | GRUB | Raspberry Pi bootloader |
| **Kernel** | Generic Debian kernel | Pi-optimized kernel |
| **Firmware** | Standard PC BIOS/UEFI | Raspberry Pi firmware |

## Build Process Flow

### x64 Build Flow

```
1. Download Debian cloud image (qcow2) → image-build/cache/
2. Convert qcow2 to raw format
3. Expand image to 5GB
4. Setup loop device and partition
5. Mount root filesystem
6. Setup chroot (proc, sys, dev)
7. Update apt repositories
8. Install prerequisites
9. Configure Kubernetes prerequisites (swap, modules, sysctl)
10. Install containerd
11. Add Kubernetes repository
12. Install Kubernetes packages (kubelet, kubeadm, kubectl)
13. Install CNI plugins (with retry logic)
14. Install crictl
15. Embed cloud-init configuration (NoCloud)
16. Cleanup chroot
17. Unmount and sync
18. Copy to output directory
19. Generate checksums and metadata
```

### Pi5 Build Flow

```
1. Setup Docker environment
2. Enable QEMU ARM64 emulation
3. Download Raspberry Pi OS image (img.xz) → image-build/cache/
4. Extract xz archive to img
5. Expand image (+2GB)
6. Setup loop device
7. Use kpartx to map partitions
8. Mount root filesystem
9. Copy qemu-aarch64-static to chroot
10. Setup chroot environment
11. Install Kubernetes and dependencies via chroot
12. Configure system for Kubernetes
13. Embed cloud-init configuration
14. Cleanup and unmount
15. Copy to output directory
```

## Advanced Configuration

### Customizing Kubernetes Version

Edit `config/base-images.conf`:
```bash
DEFAULT_K8S_VERSION="1.29.0"  # Change to desired version
```

Or override in build script:
```bash
K8S_VERSION=1.29.0 sudo ./build-x64.sh
```

### Customizing Image Size

Edit build script:
```bash
# In build-x64.sh
TARGET_SIZE="10G"  # Increase from 5G to 10G
```

### Customizing Cloud-Init

Edit the user-data section in build scripts to modify:
- User accounts
- SSH keys
- Network configuration
- Startup scripts
- Package installations

### Adding Custom Packages

Add to the build script before cloud-init configuration:
```bash
apt_retry "${ROOT_PATH}" "Install custom packages" "apt-get install -y \
    your-package-1 \
    your-package-2"
```

## Security Considerations

### Default Credentials

**⚠️ IMPORTANT**: Change default password after first boot!

```bash
# After first SSH login
passwd k8s
```

Or embed SSH keys in cloud-init config instead of using passwords.

### Image Hardening

Consider additional hardening for production:

1. **Disable password authentication**:
   ```yaml
   # In cloud-init user-data
   ssh_pwauth: false
   ```

2. **Add SSH keys only**:
   ```yaml
   users:
     - name: k8s
       ssh_authorized_keys:
         - ssh-rsa AAAA...
   ```

3. **Enable firewall**:
   ```bash
   sudo apt-get install ufw
   sudo ufw allow 22/tcp
   sudo ufw allow 6443/tcp  # Kubernetes API
   sudo ufw enable
   ```

4. **Keep system updated**:
   ```bash
   sudo apt-get update && sudo apt-get upgrade -y
   ```

## Performance Optimization

### KVM/x64 Optimizations

- **CPU**: Allocate at least 2 vCPUs per node
- **RAM**: Minimum 2GB, recommended 4GB+ for Kubernetes
- **Disk**: Use virtio for best performance
- **Network**: Use virtio-net for best network performance

### Pi5 Optimizations

- **SD Card**: Use high-quality, high-speed SD cards (Class 10, UHS-I U3)
- **Cooling**: Ensure adequate cooling for sustained performance
- **Power**: Use official Raspberry Pi power supply (5V/5A)
- **Network**: Use Gigabit Ethernet (built-in on Pi5)

## Maintenance

### Updating Base Images

When new Debian or Raspberry Pi OS releases are available:

1. Update `config/base-images.conf` with new URLs
2. Clear cache: `rm -rf image-build/cache/*`
3. Rebuild images
4. Test thoroughly before deployment

### Updating Kubernetes

1. Update `DEFAULT_K8S_VERSION` in config
2. Rebuild images
3. Test cluster initialization
4. Document any breaking changes

## Support and Contributing

### Getting Help

- Check [Troubleshooting](#troubleshooting) section
- Review build logs in `/tmp/x64-build-*.log`
- Check system logs: `journalctl -xe`

### Reporting Issues

When reporting issues, include:
- Build script output/logs
- Host system information (`uname -a`, `lsb_release -a`)
- Build script version/commit
- Steps to reproduce

## License

[Add your license here]

## Acknowledgments

- Debian Project for Debian 13 (Trixie)
- Raspberry Pi Foundation for Raspberry Pi OS
- Kubernetes project for Kubernetes
- Cloud-Init project for cloud-init

---

**Last Updated**: 2025-11-05
**OSBuild Version**: 1.0
**Tested On**: Ubuntu 22.04, KVM-enabled host
