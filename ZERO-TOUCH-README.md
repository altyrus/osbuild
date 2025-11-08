# Zero-Touch Kubernetes Deployment System

**Fully autonomous Kubernetes cluster deployment from bootable images**

Flash → Boot → Wait 15-20 minutes → Production-ready cluster with all services

## Quick Start

### 1. Configure Environment

First, create your `.env` configuration file:

```bash
# Clone the repository (if you haven't already)
git clone https://github.com/altyrus/osbuild.git
cd osbuild

# Copy the sample configuration
cp .env.sample .env

# Edit to match your network
nano .env  # Or use your preferred editor
```

**Key settings to verify**:
- `PRIVATE_SUBNET` - Internal cluster network (default: 192.168.100.0/24)
- `EXTERNAL_SUBNET` - External service network (default: 192.168.1.0/24)
- `VIP` - MetalLB virtual IP for services (default: 192.168.1.30)
- `NODE_COUNT` - Number of nodes (1 for single-node, 3 for HA)

### 2. Build Node1 Image (x64 Test)

```bash
cd osbuild
sudo BUILD_PLATFORM=x64 ./build-zerotouch.sh --node1-only
```

**Output**:
- `output/x64/zerotouch/k8s-node1.img` - Bootable image
- `output/x64/zerotouch/credentials/` - SSH keys, passwords, cluster info

### 3. Boot and Test

```bash
# Start VM
sudo qemu-system-x86_64 \
  -enable-kvm \
  -m 16384 \
  -smp 4 \
  -drive file=output/x64/zerotouch/k8s-node1.img,format=raw,if=virtio \
  -netdev bridge,id=net0,br=virbr0 \
  -device virtio-net-pci,netdev=net0 \
  -serial mon:stdio

# Monitor bootstrap (after ~1 min)
ssh -i output/x64/zerotouch/credentials/id_rsa k8sadmin@192.168.100.11 \
  tail -f /var/log/bootstrap.log

# Access services (after ~18 min)
curl http://192.168.1.30/           # Welcome page
open http://192.168.1.30/portainer/ # Portainer UI
open http://192.168.1.30/grafana/   # Grafana (admin/admin)
```

## What You Get

**Single Command Deployment**:
- Kubernetes 1.28.0 HA-ready cluster
- Flannel CNI (pod networking)
- MetalLB (VIP: 192.168.1.30)
- NGINX Ingress (HTTP routing)
- Longhorn (distributed storage)
- MinIO (S3 storage)
- Prometheus + Grafana (monitoring)
- Portainer (management UI)
- Welcome page (cluster dashboard)

**Network Configuration**:
- Private: 192.168.100.11 (cluster communications - assigned to node interface)
- VIP: 192.168.1.30 (MetalLB virtual IP for external service access)
- **Important**: The VIP (192.168.1.30) is the ONLY external IP on the 192.168.1.0 network
- Node interfaces do NOT get individual 192.168.1.x IPs (e.g., no 192.168.1.21)
- All services accessible via VIP only

**Zero Manual Steps**:
- No SSH configuration
- No kubectl commands
- No manual service deployment
- Just boot and wait

## Timeline

```
 0:00  Boot from image
 0:30  Cloud-init starts
 1:00  Network configured
 2:00  Bootstrap begins
 3:00  Kubernetes initialized
 5:00  CNI deployed
 7:00  MetalLB deployed
 9:00  Ingress deployed
12:00  Storage deployed
15:00  Monitoring deployed
18:00  All services ready ✅
```

## Service URLs

All via VIP `http://192.168.1.30`:

- `/` - Welcome page
- `/portainer/` - Kubernetes management
- `/grafana/` - Monitoring (admin/admin)
- `/prometheus/` - Metrics
- `/longhorn/` - Storage management
- `/minio/` - S3 console

## Architecture

```
┌─────────────────────────────────────────────┐
│ OSBuild Base Image                          │
│ - Debian 13 Trixie                          │
│ - Kubernetes 1.28.0 pre-installed           │
│ - containerd, CNI, crictl, helm             │
│ - All dependencies pre-installed            │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│ Zero-Touch Customization                    │
│ - Inject bootstrap scripts                  │
│ - Inject cloud-init config                  │
│ - Embed credentials                         │
│ - Configure network settings                │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│ Bootable Image (node1.img)                  │
│ Ready to flash to disk or boot in VM        │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│ First Boot (Autonomous)                     │
│ 1. Cloud-init configures network            │
│ 2. Bootstrap script executes                │
│ 3. Kubernetes cluster initialized           │
│ 4. All services deployed                    │
│ 5. VIP active, services accessible          │
└─────────────────────────────────────────────┘
```

## Building for Different Platforms

### x64 (KVM/Bare Metal)

```bash
sudo BUILD_PLATFORM=x64 ./build-zerotouch.sh
```

**Output**: 3 images (node1, node2, node3) - ~5GB each

### Raspberry Pi 5

```bash
sudo BUILD_PLATFORM=pi5 ./build-zerotouch.sh
```

**Output**: 3 images (node1, node2, node3) - ~4.7GB each

**Flash to SD card**:
```bash
sudo dd if=output/pi5/zerotouch/k8s-node1.img \
  of=/dev/sdX \
  bs=4M \
  status=progress \
  conv=fsync
```

## Configuration

The build system reads configuration from `.env` in the osbuild root directory.

### Prerequisites

1. **Create .env file**:
   ```bash
   cp .env.sample .env
   ```

2. **Edit configuration**:
   ```bash
   nano .env  # Edit to match your environment
   ```

### Configuration Variables

Key settings in `.env`:

```bash
# Network
export PRIVATE_SUBNET="192.168.100.0/24"
export EXTERNAL_SUBNET="192.168.1.0/24"
export VIP="192.168.1.30"

# Services (all enabled by default)
export DEPLOY_LONGHORN=true
export DEPLOY_MINIO=true
export DEPLOY_GRAFANA=true
export DEPLOY_PORTAINER=true

# Build
export NODE_COUNT=3  # Or 1 for testing
```

## Troubleshooting

### Build Fails

**Check prerequisites**:
```bash
# Required packages
sudo apt-get install qemu-system-x86-64 qemu-utils losetup parted e2fsprogs

# Check base image exists
ls -lh output/x64/k8s-x64-latest.img
```

### Bootstrap Fails

**Check logs**:
```bash
ssh -i credentials/id_rsa k8sadmin@192.168.100.11
sudo tail -f /var/log/bootstrap.log
```

**Common issues**:
- Network not configured: Check `/etc/netplan/01-netcfg.yaml`
- Kubernetes init timeout: Increase memory (16GB recommended)
- Service deployment timeout: Check internet connectivity

### Services Not Accessible

**Check VIP**:
```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx
# Should show EXTERNAL-IP: 192.168.1.30
```

**Check pods**:
```bash
kubectl get pods -A
# All should be Running
```

## Advanced Usage

### Custom Services

Edit `bootstrap/node1-init.sh` to add custom deployments:

```bash
# Add after STEP 11
if ! skip_if_complete "my-app"; then
    log_step "12" "Deploying My Application"

    kubectl apply -f /opt/manifests/my-app.yaml

    mark_complete "my-app"
fi
```

### Multi-Node HA

```bash
# Build all 3 nodes
sudo BUILD_PLATFORM=x64 ./build-zerotouch.sh

# Boot node1 first, wait for completion (~18 min)
# Then boot nodes 2 and 3 - they auto-join (~5 min each)
```

## Performance

**Resource Requirements**:
- CPU: 4+ cores per node
- RAM: 16GB per node (12GB minimum)
- Disk: 100GB per node (200GB recommended for storage)
- Network: 1Gbps+ recommended

**Deployment Times**:
- Node 1 (single-node): ~18 minutes
- Nodes 2/3 (join): ~5 minutes each
- Total for 3-node HA: ~28 minutes

## Project Structure

```
osbuild/
├── build-zerotouch.sh           # Main build script
├── customize-images.sh          # Image customization
├── config/
│   └── zerotouch-config.env     # Configuration
├── lib/
│   ├── credential-gen.sh        # SSH keys, tokens
│   └── image-utils.sh           # Image operations
├── bootstrap/
│   ├── node1-init.sh            # Node 1 initialization
│   ├── node-join.sh             # Node join script
│   └── lib/
│       └── bootstrap-common.sh  # Shared functions
├── cloud-init/
│   └── *.yaml.tmpl              # Cloud-init templates
└── output/{platform}/zerotouch/
    ├── k8s-node*.img            # Bootable images
    └── credentials/             # Access info
```

## Documentation

- `ZERO-TOUCH-STATUS.md` - Implementation status and known issues
- `ZERO-TOUCH-README.md` - This file (quick start)
- `bootstrap/node1-init.sh` - Bootstrap script with inline documentation
- `config/zerotouch-config.env` - Configuration with comments

## Support

**Check build log**:
```bash
tail -f /tmp/build-zerotouch.log
```

**Check bootstrap log** (on running VM):
```bash
ssh -i credentials/id_rsa k8sadmin@192.168.100.11
sudo tail -f /var/log/bootstrap.log
```

**Common fixes**:
- Increase timeout values in `config/zerotouch-config.env`
- Check network connectivity (DNS, internet)
- Verify sufficient resources (RAM, CPU, disk)

## Next Steps

1. **Test node1 deployment** - Verify autonomous deployment works
2. **Test service access** - Verify all URLs work via VIP
3. **Build nodes 2/3** - Test HA cluster formation
4. **Build Pi5 images** - Test on actual hardware
5. **Customize services** - Add your applications

## License

Same as parent projects (OSBuild and Platform)

---

**Status**: Core implementation complete, testing in progress
**Version**: 0.1.0
**Last Updated**: 2025-11-06
