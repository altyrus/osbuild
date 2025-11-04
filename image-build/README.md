# Image Build

This directory contains the scripts and configurations for building Raspberry Pi 5 OS images with Kubernetes support.

## Directory Structure

```
image-build/
├── scripts/              # Build scripts executed during image creation
│   ├── 01-install-k8s.sh        # Install Kubernetes components
│   ├── 02-install-bootstrap.sh  # Install bootstrap framework
│   ├── 03-configure-firstboot.sh # Configure first-boot service
│   └── 04-cleanup.sh            # Cleanup and optimize image
├── files/                # Files to be embedded in the image
│   ├── bootstrap/        # Bootstrap scripts
│   └── systemd/          # Systemd service units
├── cache/                # Downloaded base images (gitignored)
└── work/                 # Build working directory (gitignored)
```

## Build Process

The build process follows these stages:

1. **Download Base Image**: Raspberry Pi OS Lite (64-bit)
2. **Expand Image**: Add space for packages and customization
3. **Mount Partitions**: Mount boot and root filesystems
4. **Install K8s**: Install containerd, kubeadm, kubelet, kubectl
5. **Install Bootstrap**: Add first-boot provisioning framework
6. **Configure Services**: Enable first-boot systemd service
7. **Cleanup**: Remove temporary files and optimize image size
8. **Extract Artifacts**: Create both disk.img and rootfs.tar.gz

## Manual Build

To build the image manually (outside CI/CD):

```bash
# Install dependencies
sudo apt-get install qemu-user-static qemu-utils debootstrap kpartx parted wget curl jq xz-utils

# Download base image
cd cache
wget https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-07-04/2024-07-04-raspios-bookworm-arm64-lite.img.xz

# Extract and build
cd ..
./scripts/build-local.sh
```

## Customization

### Kubernetes Version

Set via environment variable or workflow input:

```bash
export K8S_VERSION=1.28.0
```

### Bootstrap Configuration

Edit files in `image-build/files/bootstrap/` to customize the first-boot behavior.

### Additional Packages

Add to `scripts/01-install-k8s.sh` or create additional numbered scripts.

## Output Artifacts

- `output/rpi5-k8s-VERSION.img` - Full disk image for NVMe flashing
- `output/netboot/rootfs.tar.gz` - Root filesystem for netboot deployment
- `output/metadata.json` - Build metadata and version information
- `output/*.sha256` - Checksums for verification

## Troubleshooting

### Build fails during mount

Ensure loop devices are available:
```bash
sudo modprobe loop
```

### Insufficient disk space

The build requires at least 10GB free space. Check with:
```bash
df -h
```

### Permission errors

All mount/partition operations require root privileges. Ensure sudo is available.
