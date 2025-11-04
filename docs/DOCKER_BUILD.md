# Docker Build Guide

Build Raspberry Pi 5 OS images using **only Docker** - no other dependencies needed.

## Why Docker Build?

✅ **Zero host installation** - Only Docker required
✅ **Portable** - Works on any OS with Docker (Linux, macOS, Windows)
✅ **Reproducible** - Same environment every time
✅ **Isolated** - No pollution of host system
✅ **Simple** - Clone repo, run one command

## Prerequisites

- Docker installed and running
- 10GB free disk space
- Privileged mode access (for loop devices)

## Quick Start

### Method 1: Simple Script (Recommended)

**No docker-compose needed, just Docker:**

```bash
# Clone the repo
git clone https://github.com/altyrus/osbuild.git
cd osbuild

# Build with defaults (output to ./output, K8s 1.28.0)
./docker-build-simple.sh

# Custom output directory
./docker-build-simple.sh /path/to/output

# Custom Kubernetes version
./docker-build-simple.sh ./output 1.29.0
```

**That's it!** Image will be in your output directory in 15-30 minutes.

### Method 2: docker-compose

**If you have docker-compose:**

```bash
git clone https://github.com/altyrus/osbuild.git
cd osbuild

# Build with defaults
./docker-build.sh

# Custom settings
OUTPUT_DIR=/path/to/output K8S_VERSION=1.29.0 ./docker-build.sh
```

### Method 3: Pure Docker Commands

**For complete control:**

```bash
# Build the image
docker build -t osbuild:latest .

# Run the build
docker run --rm --privileged \
    -v $(pwd)/output:/workspace/output \
    -v $(pwd)/image-build/cache:/workspace/image-build/cache \
    -e K8S_VERSION=1.28.0 \
    osbuild:latest
```

## What Gets Built

After the build completes, you'll have:

```
output/
├── rpi5-k8s-docker-TIMESTAMP.img        # Disk image for NVMe
├── rpi5-k8s-docker-TIMESTAMP.img.sha256 # Checksum
├── metadata.json                         # Build info
└── netboot/
    ├── rootfs.tar.gz                     # Root filesystem for netboot
    └── rootfs.tar.gz.sha256              # Checksum
```

## Usage Examples

### Basic Build

```bash
./docker-build-simple.sh
# Output: ./output/rpi5-k8s-*.img
```

### Custom Output Location

```bash
./docker-build-simple.sh /mnt/storage/images
# Output: /mnt/storage/images/rpi5-k8s-*.img
```

### Different Kubernetes Version

```bash
./docker-build-simple.sh ./output 1.29.0
# Builds with Kubernetes 1.29.0
```

### Cache Reuse (Faster Rebuilds)

```bash
# First build downloads base image (~500MB)
./docker-build-simple.sh

# Second build reuses cache (much faster)
./docker-build-simple.sh
```

### Parallel Builds (Different Versions)

```bash
# Terminal 1: Build K8s 1.28
OUTPUT_DIR=./output-1.28 K8S_VERSION=1.28.0 ./docker-build-simple.sh

# Terminal 2: Build K8s 1.29
OUTPUT_DIR=./output-1.29 K8S_VERSION=1.29.0 ./docker-build-simple.sh
```

## Environment Variables

All scripts support these environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `OUTPUT_DIR` | `./output` | Where to save built images |
| `K8S_VERSION` | `1.28.0` | Kubernetes version to install |
| `IMAGE_VERSION` | `docker-TIMESTAMP` | Custom version identifier |
| `CACHE_DIR` | `./image-build/cache` | Cache for base images |

Example:
```bash
export OUTPUT_DIR=/mnt/storage
export K8S_VERSION=1.29.0
export IMAGE_VERSION=my-custom-v1
./docker-build-simple.sh
```

## How It Works

The Docker build process:

1. **Container Setup** - Pulls Ubuntu 22.04, installs build tools
2. **Download** - Fetches Raspberry Pi OS base image (~500MB, cached)
3. **Expand** - Adds 2GB space for packages
4. **Mount** - Mounts image partitions using loop devices
5. **Install K8s** - Installs containerd, kubeadm, kubelet, kubectl
6. **Bootstrap** - Adds first-boot provisioning framework
7. **Configure** - Sets up systemd services and boot config
8. **Cleanup** - Removes temporary files, optimizes size
9. **Shrink** - Minimizes image to ~2.1GB
10. **Extract** - Creates both disk.img and rootfs.tar.gz
11. **Output** - Saves to your host directory

Total time: **15-30 minutes** (depends on CPU, first build downloads ~500MB)

## Dockerfile Explained

```dockerfile
FROM ubuntu:22.04

# Install build dependencies
RUN apt-get update && apt-get install -y \
    qemu-user-static    # ARM64 emulation
    kpartx parted       # Partition tools
    wget curl jq        # Download tools
    # ... and more

# Copy build scripts
COPY image-build /workspace/image-build
COPY scripts /workspace/scripts

# Run build on container start
CMD ["/workspace/scripts/docker-entrypoint.sh"]
```

Everything is self-contained in the container.

## Customization

### Custom Kubernetes Version

```bash
./docker-build-simple.sh ./output 1.30.0
```

### Custom Base Image

Edit `Dockerfile` or set environment variable:
```bash
export RASPIOS_VERSION=2024-10-01-raspios-bookworm-arm64-lite
./docker-build-simple.sh
```

### Modify Build Scripts

Build scripts are copied into the image:
- Edit: `image-build/scripts/01-install-k8s.sh` (Kubernetes setup)
- Edit: `image-build/scripts/02-install-bootstrap.sh` (Bootstrap config)
- Edit: `image-build/scripts/03-configure-firstboot.sh` (First-boot setup)
- Edit: `image-build/scripts/04-cleanup.sh` (Optimization)

Then rebuild the Docker image:
```bash
docker build -t osbuild:latest .
./docker-build-simple.sh
```

## Troubleshooting

### "Docker is not running"

```bash
# Linux
sudo systemctl start docker

# macOS
# Start Docker Desktop

# Windows
# Start Docker Desktop
```

### "Permission denied" or "Operation not permitted"

The container needs privileged mode for loop devices:

```bash
# Ensure --privileged flag is used
docker run --rm --privileged ...
```

This is safe - the container is isolated.

### "Not enough disk space"

Build requires ~10GB:
- 500MB base image download
- 2GB+ during build
- 2GB final output
- 5GB+ for Docker layers

Free up space:
```bash
# Remove old Docker images
docker system prune -a

# Check available space
df -h
```

### "Download is slow"

First build downloads 500MB Raspberry Pi OS image. It's cached for subsequent builds.

Speed up:
- Use wired internet
- Download manually and place in `./image-build/cache/`
- Wait it out (only happens once)

### "Build fails at mount step"

Ensure Docker has privileged access:

**Linux**: Should work by default
**macOS**: Docker Desktop may need settings adjustment
**Windows**: WSL2 backend recommended

### "Image won't boot on Raspberry Pi"

Verify checksum:
```bash
cd output
sha256sum -c rpi5-k8s-*.img.sha256
```

Flash with correct options:
```bash
sudo dd if=rpi5-k8s-*.img of=/dev/nvme0n1 bs=4M status=progress conv=fsync
```

## Comparison: Docker vs Other Methods

| Method | Setup Time | Build Time | Reproducible | Portable |
|--------|------------|------------|--------------|----------|
| **Docker** | 0 min | 20 min | ✅ Yes | ✅ Any OS |
| GitHub Actions | 0 min | 10 min | ✅ Yes | ☁️ Cloud only |
| Native Local | 5 min | 15 min | ⚠️ Depends | 🐧 Linux only |
| Self-hosted Runner | 15 min | 10 min | ✅ Yes | 🐧 Linux only |

Docker is the best for **portability** and **zero setup**.

## Advanced Usage

### Build in CI/CD (GitLab CI, Jenkins, etc.)

```yaml
# .gitlab-ci.yml
build-image:
  image: docker:latest
  services:
    - docker:dind
  script:
    - cd osbuild
    - ./docker-build-simple.sh /builds/output
  artifacts:
    paths:
      - /builds/output/*.img
```

### Build on Windows

```powershell
# PowerShell
git clone https://github.com/altyrus/osbuild.git
cd osbuild
.\docker-build-simple.sh C:\output
```

### Build on macOS

```bash
# Same as Linux
git clone https://github.com/altyrus/osbuild.git
cd osbuild
./docker-build-simple.sh ./output
```

### Automated Builds with Cron

```bash
# Build nightly at 2 AM
crontab -e

# Add:
0 2 * * * cd /home/user/osbuild && ./docker-build-simple.sh /mnt/storage/images/$(date +\%Y\%m\%d)
```

## Performance Tips

### Use SSD for Output

```bash
# Faster writes
./docker-build-simple.sh /mnt/ssd/output
```

### Increase Docker Resources

Docker Desktop → Settings → Resources:
- CPU: 4+ cores
- Memory: 8+ GB
- Disk: 20+ GB

### Keep Cache

Don't delete `./image-build/cache/` between builds - it contains the 500MB base image.

## FAQ

**Q: Do I need docker-compose?**
A: No, use `docker-build-simple.sh` for pure Docker.

**Q: Can I run this in CI/CD?**
A: Yes, any CI/CD with Docker support works.

**Q: Does it work on ARM Macs (M1/M2)?**
A: Yes, Docker handles architecture translation.

**Q: Can I build multiple versions in parallel?**
A: Yes, use different OUTPUT_DIR for each build.

**Q: How do I clean up?**
A: `docker system prune -a` removes all build artifacts.

**Q: Why privileged mode?**
A: Needed for loop devices to mount image partitions. Container is isolated and safe.

## Summary

**Simplest possible workflow:**

```bash
git clone https://github.com/altyrus/osbuild.git
cd osbuild
./docker-build-simple.sh
# Wait 15-30 minutes
# Image is in ./output/
```

**No installation, no configuration, no hassle.**

Just Docker and go! 🚀
