# Zero-Touch Kubernetes Test - Compact Summary

## Date: 2025-11-07 | Duration: 90 minutes | 2 test iterations

### Test 1: 40GB Disk ✅ Partial / ❌ Storage Failed
- **Bootstrap**: 17.5 min to "complete" (script doesn't validate pod readiness)
- **Success**: K8s cluster, Flannel, MetalLB (VIP 192.168.1.30), NGINX Ingress, Longhorn deployed
- **Failure**: MinIO(50GB), Grafana(10GB), Prometheus(10GB), Portainer(10GB) PVCs all faulted
- **Cause**: Only 32GB available, 80GB requested → Longhorn "insufficient storage" errors
- **Services Working**: Welcome page, Longhorn UI | **Failed**: Portainer, Grafana, Prometheus (503)

### Test 2: 120GB Disk ✅ Build / ❌ Network Blocked
- **Success**: Built 120GB base image + zero-touch image correctly
- **Blocker**: Network mismatch - VM uses 192.168.100.11 static IP, libvirt default is 192.168.122.x
- **Result**: "No route to host" - couldn't test bootstrap with adequate storage
- **Needs**: Custom libvirt network or bridge setup for 192.168.100.0/24 subnet

## Changes Made
1. ✅ **config/base-images.conf:28-29** - X64_TARGET_SIZE: 40G → 120G, RPI5: 4.5G → 120G
2. ✅ **ZERO-TOUCH-README.md:76-81** - Clarified VIP-only external access (no per-node 192.168.1.x IPs)
3. ✅ **TEST-RESULTS.md** - Full detailed test report created
4. ✅ **COMPACT-SUMMARY.md** - This summary

## Key Findings
- **Minimum Disk**: 120GB for production (OS 7GB + Longhorn PVCs 80GB + buffer 33GB)
- **Storage Behavior**: Longhorn over-provisioning allows 2x requests but needs physical space for replicas
- **Network Issue**: Zero-touch uses custom subnets, requires matching libvirt network (not "default")
- **Build Process**: Must clear output-zerotouch-x64/ cache when base image changes

## Next Test Requirements
1. Setup libvirt network for 192.168.100.0/24 (or use test-libvirt-network.sh if exists)
2. Create VM with `--network network=k8s-private` (not --network network=default)
3. Verify 120GB partition expansion at boot (growpart/resize2fs)
4. Monitor full 18-min bootstrap with adequate storage
5. Validate all services accessible via VIP 192.168.1.30

## Status
- **Architecture**: ✅ Sound - bootstrap process works autonomously
- **40GB Config**: ❌ Production inadequate
- **120GB Config**: ⚠️ Untested due to network - theoretically viable
