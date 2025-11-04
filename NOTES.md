# OSBuild Project Notes

## Quick Reference

### Project Location
- **Path**: `/POOL01/software/projects/osbuild`
- **GitHub**: https://github.com/altyrus/osbuild
- **Owner**: altyrus (Scot Gray - scot.gray@altyrus.com)

### Key Decisions

**Deployment Strategy: Hybrid Approach**
- **Development/Testing**: Netboot (diskless Raspberry Pi 5s)
- **Production**: NVMe storage images
- **Rationale**: Fast iteration in dev, reliability in production

**Image Build Philosophy**
- Single CI/CD pipeline produces both formats
- Generic images with NO manual configuration
- First-boot auto-provisioning via git-pulled scripts
- Separation of concerns: OS image (stable) vs bootstrap scripts (dynamic)

### Critical Insights

1. **Why NOT SD Cards**
   - Frequent failures require physical intervention
   - Configuration drift over time
   - Update pain (flash 20+ cards or risk divergence)
   - Operational burden increases with scale

2. **Why Netboot for Dev**
   - Change image → reboot → test in <10 minutes
   - True stateless nodes
   - Centralized image management
   - No physical media failures

3. **Why NVMe for Production**
   - More reliable than SD cards
   - No network dependency for boot (after provisioning)
   - Can survive network issues
   - Standard deployment method

4. **Network Dependency Reality Check**
   - K8s clusters are non-functional without network anyway
   - etcd, pod networking, storage all need network
   - Netboot's network dependency is NOT a new failure mode

### Architecture Summary

```
Single Image Build
    ├── Base OS (Raspberry Pi OS 64-bit)
    ├── Bootstrap Layer (first-boot service)
    ├── K8s Prerequisites (kubeadm, kubelet, containerd)
    └── Output
        ├── rootfs.tar.gz (for netboot NFS)
        └── disk.img (for NVMe flashing)
```

### First-Boot Automation Flow

```
Power On
    ↓
Boot (netboot or NVMe)
    ↓
First-boot systemd service runs
    ↓
Multi-factor provisioning check:
  1. /var/lib/node-provisioned exists?
  2. kubelet running?
  3. Node in cluster?
    ↓
If NOT provisioned:
  1. Get node identity (MAC/serial)
  2. Fetch bootstrap scripts from git
  3. Execute setup.sh with retry
  4. Join K8s cluster
  5. Mark as provisioned
    ↓
Done
```

### Node Identity

**MAC-based (initial approach)**
- Pre-configure `nodes.yaml` with MAC addresses
- Simple and deterministic
- Example:
  ```yaml
  nodes:
    - mac: "dc:a6:32:12:34:56"
      hostname: "k8s-master-01"
      role: "control-plane"
      ip: "10.0.10.10"
  ```

**Future: API-based registration**
- Dynamic node registration
- Better for scaling beyond initial deployment

### Repository Structure

```
osbuild/                        # Main repo (OS image building)
├── image-build/
│   ├── packer/
│   ├── scripts/
│   └── files/
├── netboot/
│   ├── dnsmasq.conf
│   └── nfs-exports
├── .github/workflows/
│   └── build-image.yml
└── docs/

k8s-bootstrap/                  # Separate repo (configuration/scripts)
├── setup.sh
├── config/
│   ├── nodes.yaml
│   └── environments/
├── scripts/
│   ├── 00-system-prep.sh
│   ├── 01-storage-setup.sh
│   ├── 02-k8s-init.sh
│   ├── 03-cni-install.sh
│   └── 04-apps-deploy.sh
└── manifests/
```

### Key Files (Baked into Image)

**`/opt/bootstrap/bootstrap.sh`**
- Detects first boot
- Fetches setup scripts from git
- Executes provisioning
- Marks node as provisioned

**`/etc/systemd/system/first-boot.service`**
- Runs bootstrap.sh on every boot
- Conditional: only if not already provisioned
- Has network dependency

**`/var/lib/node-provisioned`**
- State file created after successful provisioning
- Prevents re-provisioning on reboot

### Boot Mode Detection

```bash
get_boot_mode() {
    if grep -q "nfsroot" /proc/cmdline; then
        echo "netboot"
    elif [[ -b /dev/nvme0n1 ]]; then
        echo "nvme"
    fi
}
```

### Persistent Storage Considerations

**Netboot:**
- etcd: Separate NFS export or dedicated storage
- `/var/lib/kubelet`: Must persist across reboots
- Logs: Remote logging or memory-based

**NVMe:**
- All persistent data on local storage
- Partition layout: boot + root + data
- Auto-expand root on first boot

### CI/CD Pipeline (GitHub Actions)

**Triggers:**
- Push to main → Build and deploy to netboot (dev)
- Tag push (v*) → Build and publish release (prod)

**Outputs:**
- `disk.img` + checksums
- `rootfs.tar.gz` for NFS
- `metadata.json` with version info

### Implementation Phases

**Phase 1: Foundation (Week 1-2)**
- CI/CD pipeline for image building
- Basic Packer/pi-gen configuration
- First-boot detection service
- Minimal bootstrap.sh

**Phase 2: Netboot Dev (Week 2-3)**
- Set up netboot server (dnsmasq + NFS)
- Deploy rootfs to NFS
- Test with 1-2 Pis
- Iterate until auto-clustering works

**Phase 3: Bootstrap Scripts (Week 3-4)**
- Full script suite development
- Node inventory management
- K8s integration
- End-to-end testing

**Phase 4: NVMe Production (Week 4-5)**
- Flash image to NVMe
- Production validation
- Performance testing

**Phase 5: Operations (Ongoing)**
- Monitoring and reliability
- Update procedures
- Runbooks and documentation

### Tools Required

**Build Environment:**
- Packer (with QEMU ARM64 support)
- or pi-gen (official Raspberry Pi tool)
- GitHub Actions or GitLab CI

**Netboot Server:**
- dnsmasq (DHCP + TFTP)
- NFS server
- HTTP server (optional, faster than TFTP)

**Production:**
- Raspberry Pi 5
- NVMe drives with M.2 adapter
- Network infrastructure

### Security Considerations

1. **Bootstrap Script Verification**
   - Sign git commits (GPG)
   - Verify signatures before execution
   - Or use checksum verification

2. **Secrets Management**
   - Never bake secrets into images
   - Use K8s secrets or external vault
   - Bootstrap should fetch secrets securely

3. **Network Security**
   - HTTPS for bootstrap downloads
   - Mutual TLS for node registration API
   - Isolated VLAN for netboot (TFTP/NFS)

### Team Collaboration

- **GitHub**: Primary development (altyrus org)
- **Google Drive**: Documentation sharing for team members without GitHub access
- Manual sync: Copy repo to Google Drive as needed

### Environment Setup Completed

1. ✅ Installed GitHub CLI (`gh`)
2. ✅ Configured passwordless sudo for package installation
3. ✅ Authenticated with GitHub (user: altyrus)
4. ✅ Created and pushed initial repository
5. ✅ Git configured: Scot Gray <scot.gray@altyrus.com>

### Next Steps

Choose implementation starting point:
1. Set up CI/CD pipeline structure
2. Create Packer configuration for image building
3. Develop bootstrap script framework
4. Configure netboot server
5. Build node inventory system

### Quick Commands Reference

**Build new image (future):**
```bash
cd image-build
packer build raspberry-pi.pkr.hcl
```

**Flash to NVMe:**
```bash
sudo dd if=disk.img of=/dev/nvme0n1 bs=4M status=progress
```

**Deploy to netboot:**
```bash
./scripts/deploy-netboot.sh output/rootfs.tar.gz
```

**Check node provisioning status:**
```bash
ssh pi@node "systemctl status first-boot.service"
ssh pi@node "cat /var/lib/node-provisioned"
```

### Key URLs

- Repository: https://github.com/altyrus/osbuild
- Raspberry Pi netboot docs: https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#network-booting
- Packer: https://www.packer.io/
- pi-gen: https://github.com/RPi-Distro/pi-gen

### Success Criteria

**Development:**
- Power on Pi → Netboot → Auto-join cluster in <5 minutes

**Production:**
- Flash NVMe → Insert → Power on → Auto-join cluster in <10 minutes
- Zero manual configuration required
- Nodes are truly cattle, not pets

### Philosophy

> "Don't fight the Kubernetes philosophy of ephemeral nodes. Embrace it with stateless OS images and externalized configuration."

- OS image = infrastructure layer (stable, versioned)
- Bootstrap scripts = configuration layer (dynamic, git-controlled)
- State = external to nodes (distributed storage)
- Nodes = completely disposable and replaceable
