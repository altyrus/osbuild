# Zero-Touch Deployment Fixes - Session 2025-11-06

## Overview
This document records all issues discovered and fixed during zero-touch Kubernetes deployment testing. These fixes are required for fully autonomous deployments.

**Latest Update**: 2025-11-07 00:55 UTC - Full zero-touch deployment test completed with mixed results

## Critical Issues Fixed

### 1. Base Image Size - FIXED
**Problem**: Base image was 5GB instead of required 40GB
**Root Cause**: Symlink `k8s-x64-latest.img` pointed to old 5GB image
**Fix Applied**:
```bash
cd /POOL01/software/projects/osbuild/output-x64
sudo rm -f k8s-x64-latest.img
sudo ln -s k8s-x64-20251106-152421.img k8s-x64-latest.img
```
**Config File**: [base-images.conf:28](/POOL01/software/projects/osbuild/config/base-images.conf#L28)
```bash
X64_TARGET_SIZE="40G"
```
**Status**: ✅ Verified - Image now 40GB

---

### 2. Kubeconfig Not Configured for k8sadmin User - NEEDS BOOTSTRAP FIX
**Problem**: kubectl commands fail with "connection refused to localhost:8080"
**Root Cause**: Bootstrap script doesn't copy admin.conf to user's ~/.kube/config
**Manual Fix Applied**:
```bash
mkdir -p /home/k8sadmin/.kube
sudo cp /etc/kubernetes/admin.conf /home/k8sadmin/.kube/config
sudo chown k8sadmin:k8sadmin /home/k8sadmin/.kube/config
```

**REQUIRED BOOTSTRAP FIX**: Add to [bootstrap/node1-init.sh](/POOL01/software/projects/osbuild/bootstrap/node1-init.sh) after kubeadm init:
```bash
# Configure kubectl for k8sadmin user
log_info "Configuring kubectl for ${SSH_USER} user"
mkdir -p /home/${SSH_USER}/.kube
sudo cp -f /etc/kubernetes/admin.conf /home/${SSH_USER}/.kube/config
sudo chown ${SSH_USER}:${SSH_USER} /home/${SSH_USER}/.kube/config
log_success "✓ kubectl configured for ${SSH_USER}"
```
**Status**: ⚠️  Manual fix worked - Bootstrap script needs update

---

### 3. CNI Flannel Plugin Symlink Missing - NEEDS BOOTSTRAP FIX
**Problem**: All pods stuck in ContainerCreating with error:
```
failed to find plugin "flannel" in path [/usr/lib/cni]
```
**Root Cause**: Flannel binary installed to `/opt/cni/bin/flannel` but containerd looks in `/usr/lib/cni/`
**Manual Fix Applied**:
```bash
sudo ln -sf /opt/cni/bin/flannel /usr/lib/cni/flannel
sudo systemctl restart containerd
```

**REQUIRED BOOTSTRAP FIX**: Add to [bootstrap/node1-init.sh](/POOL01/software/projects/osbuild/bootstrap/node1-init.sh) after Flannel deployment:
```bash
# Create flannel symlink for containerd
log_info "Creating flannel CNI plugin symlink"
if [ -f /opt/cni/bin/flannel ] && [ ! -f /usr/lib/cni/flannel ]; then
    sudo ln -sf /opt/cni/bin/flannel /usr/lib/cni/flannel
    log_success "✓ Flannel symlink created"

    # Restart containerd to pick up the new plugin
    sudo systemctl restart containerd
    sleep 5
fi
```

**Alternative Fix** (better - do during customization): Add to [customize-images.sh](/POOL01/software/projects/osbuild/customize-images.sh) in CNI symlink section (around line 320):
```bash
# NOTE: Flannel binary will be installed by Flannel DaemonSet, but we need to ensure
# the symlink will be created. Add a systemd service to watch for it.
cat > "$MOUNT_POINT/usr/local/bin/ensure-flannel-symlink.sh" <<'FLANNELSCRIPT'
#!/bin/bash
# Wait for flannel binary and create symlink
for i in {1..60}; do
    if [ -f /opt/cni/bin/flannel ] && [ ! -L /usr/lib/cni/flannel ]; then
        ln -sf /opt/cni/bin/flannel /usr/lib/cni/flannel
        systemctl restart containerd
        exit 0
    fi
    sleep 5
done
FLANNELSCRIPT

chmod +x "$MOUNT_POINT/usr/local/bin/ensure-flannel-symlink.sh"

# Create systemd service
cat > "$MOUNT_POINT/etc/systemd/system/flannel-symlink.service" <<'SVCFILE'
[Unit]
Description=Ensure Flannel CNI Plugin Symlink
After=containerd.service
Wants=containerd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ensure-flannel-symlink.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCFILE

ln -sf /etc/systemd/system/flannel-symlink.service "$MOUNT_POINT/etc/systemd/system/multi-user.target.wants/flannel-symlink.service"
```

**Status**: ⚠️  Manual fix worked - Needs permanent solution in customization or bootstrap

---

### 4. MetalLB Configuration Not Applied - NEEDS BOOTSTRAP FIX
**Problem**: MetalLB speaker pod fails to start - missing "memberlist" secret
**Root Cause**: Bootstrap script timed out before applying IPAddressPool and L2Advertisement
**Manual Fix Applied**:
```bash
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.1.30-192.168.1.30
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
EOF
```

**REQUIRED BOOTSTRAP FIX**: The bootstrap script should already have this logic - the issue was the script stopped due to CNI timeout. Once fix #3 is applied, this should work automatically.

**Location**: Should be in bootstrap after MetalLB deployment
**Status**: ⚠️  Manual fix worked - Will work automatically once CNI fix applied

---

## Issues Already Fixed in Previous Session

### 5. DNS Configuration - FIXED
**Problem**: Manual `resolvectl` commands needed after boot
**Fix**: Added zerotouch-dns.service in [customize-images.sh:302-378](/POOL01/software/projects/osbuild/customize-images.sh#L302-L378)
**Status**: ✅ Working

### 6. Network Configuration - FIXED
**Problem**: Static IP not properly configured
**Fix**: Updated cloud-init user-data and added zerotouch-network.service
**Status**: ✅ Working

---

## Deployment Results

### Successfully Deployed (Manual Fixes)
- ✅ Kubernetes 1.28.0 cluster
- ✅ 40GB disk partition
- ✅ Flannel CNI (after symlink fix)
- ✅ CoreDNS (2 replicas)
- ✅ MetalLB controller + speaker (after config fix)
- ✅ Static IP: 192.168.100.11/24
- ✅ VIP configured: 192.168.1.30

### Not Yet Deployed (Bootstrap Stopped Early)
- ⏳ NGINX Ingress Controller
- ⏳ Longhorn storage
- ⏳ Prometheus
- ⏳ Grafana
- ⏳ MinIO

---

## Required Files to Update for Zero-Touch

### Priority 1: Critical Fixes
1. **[bootstrap/node1-init.sh](/POOL01/software/projects/osbuild/bootstrap/node1-init.sh)**
   - Add kubeconfig setup (Fix #2)
   - Add flannel symlink creation (Fix #3)

2. **[customize-images.sh](/POOL01/software/projects/osbuild/customize-images.sh)**
   - Add flannel-symlink.service (Fix #3 alternative)

### Priority 2: Verification
3. **Bootstrap script timeout handling**
   - Review MetalLB wait logic - currently uses kubectl wait which requires working CNI
   - May need to retry or extend timeout

---

## Test Results

### VM Configuration
- **Name**: k8s-node1
- **Memory**: 16GB
- **CPUs**: 4
- **Disk**: 40GB (verified: `/dev/vda1 40G 3.1G 35G 9%`)
- **Network**: virbr-k8s (192.168.100.0/24)
- **IP**: 192.168.100.11

### Pod Status (All Running)
```
NAMESPACE        PODS                                READY   STATUS
kube-flannel     kube-flannel-ds-m4zdv               1/1     Running
kube-system      coredns-5dd5756b68-krmsk            1/1     Running
kube-system      coredns-5dd5756b68-zkv9z            1/1     Running
kube-system      etcd-k8s-node1                      1/1     Running
kube-system      kube-apiserver-k8s-node1            1/1     Running
kube-system      kube-controller-manager-k8s-node1   1/1     Running
kube-system      kube-proxy-wwr97                    1/1     Running
kube-system      kube-scheduler-k8s-node1            1/1     Running
metallb-system   controller-7499d4584d-wp8f5         1/1     Running
metallb-system   speaker-fnzkt                       1/1     Running
```

---

## Summary for Next Deployment

To achieve full zero-touch deployment:

1. ✅ **40GB disk** - Config updated, working
2. ✅ **DNS automation** - Service created, working
3. ✅ **Network configuration** - Cloud-init configured, working
4. ⚠️  **Kubeconfig setup** - Needs bootstrap script update
5. ⚠️  **Flannel CNI symlink** - Needs customization or bootstrap update
6. ⚠️  **Service deployments** - Will work once CNI fix applied

**Estimated time to fix**: 30-60 minutes to update bootstrap script
**Expected result**: Fully autonomous deployment with all services

---

## Files Modified This Session

- [config/base-images.conf](/POOL01/software/projects/osbuild/config/base-images.conf) - X64_TARGET_SIZE=40G
- [output-x64/k8s-x64-latest.img](/POOL01/software/projects/osbuild/output-x64/k8s-x64-latest.img) - Symlink updated
- [output-zerotouch-x64/credentials/](/POOL01/software/projects/osbuild/output-zerotouch-x64/credentials/) - SSH keys regenerated

**No bootstrap script updates applied yet** - All fixes were manual for testing

---

---

## FINAL TEST RESULTS - Full Zero-Touch Deployment

### Test Execution Summary
- **Date**: 2025-11-07 00:42-00:53 UTC
- **Image**: k8s-node1.img (40GB, with updated bootstrap script)
- **Bootstrap Updates Applied**: Fixes #1 (kubeconfig) and #2 (Flannel symlink)
- **Deployment Method**: Fully autonomous via deploy-and-monitor.sh

### What Worked Autonomously ✅

1. **VM Boot and Network** (14 seconds)
   - SSH accessible at 192.168.100.11
   - Static IP configuration working
   - DNS resolution working (zerotouch-dns.service)

2. **Kubernetes Cluster Initialization**
   - kubeadm init completed successfully
   - Control plane pods deployed
   - API server accessible

3. **CNI Flannel Symlink Fix** ✅ **VERIFIED WORKING**
   ```
   [SUCCESS] 00:44:17 Flannel symlink created
   ```
   - Bootstrap code executed at lines 167-179
   - Symlink created: `/usr/lib/cni/flannel` -> `/opt/cni/bin/flannel`
   - containerd restarted automatically
   - Flannel DaemonSet ready: 1/1 pods

4. **MetalLB Deployment**
   - MetalLB v0.14.9 applied successfully
   - Controller pod ready (00:44:24)
   - Speaker DaemonSet ready: 1/1 (00:45:25)
   - VIP 192.168.1.30 configured and operational

5. **NGINX Ingress Controller**
   - v1.11.3 deployed successfully
   - LoadBalancer service assigned VIP 192.168.1.30
   - Ingress controller pod running

6. **Longhorn Partial Deployment**
   - Longhorn v1.7.2 applied
   - longhorn-manager DaemonSet ready: 1/1 (00:47:59)
   - Bootstrap stopped during CSI component wait

### Critical Issues Discovered ⚠️

#### Issue #4: Bootstrap Failed Before Kubeconfig Setup
**Problem**: The kubeconfig setup code (Fix #1, lines 137-144) never executed
**Evidence**:
- `/home/k8sadmin/.kube/` directory does not exist
- kubectl fails for k8sadmin user: "connection to server localhost:8080 was refused"
- `sudo kubectl` also fails with same error

**Root Cause Analysis Needed**:
- Bootstrap appears to have failed earlier than expected
- Possible causes:
  1. Bootstrap script exited prematurely
  2. SSH_USER variable not set during cloud-init
  3. Bootstrap ran but skipped kubeconfig section
  4. Bootstrap crashed/stopped before reaching line 137

**Investigation Required**:
```bash
# Check bootstrap log for kubeconfig execution
grep -A5 -B5 "Configuring kubectl for" /var/log/bootstrap.log

# Check if SSH_USER was set
grep SSH_USER /var/log/cloud-init-output.log

# Check bootstrap completion markers
ls -la /opt/bootstrap/.complete/
```

#### Issue #5: Longhorn CSI Deployment Name Mismatch
**Problem**: Bootstrap waiting for deployment "csi-provisioner" which doesn't exist
**Error**: `Error from server (NotFound): deployments.apps "csi-provisioner" not found`
**Impact**: Bootstrap stopped at Longhorn deployment, never deployed:
- Prometheus
- Grafana
- MinIO
- Portainer
- Welcome Page

**Root Cause**: Longhorn v1.7.2 may have different CSI component names
**Fix Required**: Update bootstrap to check for correct Longhorn CSI deployment names

**Investigation Commands**:
```bash
# List actual Longhorn deployments
kubectl get deployments -n longhorn-system

# Expected names might be:
# - longhorn-driver-deployer
# - csi-attacher
# - csi-provisioner (if it exists with different label)
```

### Services Successfully Deployed
1. ✅ Kubernetes 1.28.0 control plane
2. ✅ Flannel CNI with symlink fix
3. ✅ CoreDNS (2 replicas)
4. ✅ MetalLB controller + speaker with VIP 192.168.1.30
5. ✅ NGINX Ingress Controller with VIP 192.168.1.30
6. ⚠️ Longhorn manager DaemonSet (partial - CSI check failed)

### Services NOT Deployed
- ⏳ Longhorn CSI components (check failed)
- ⏳ Prometheus monitoring
- ⏳ Grafana dashboards
- ⏳ MinIO object storage
- ⏳ Portainer management UI
- ⏳ Welcome Page

### Bootstrap Script Status
**Lines Executed Successfully**:
- Lines 1-136: Kubernetes init ✅
- Lines 137-144: Kubeconfig setup ❌ (NOT executed - reason unknown)
- Lines 157-181: Flannel CNI + symlink ✅
- Lines 188-239: MetalLB deployment ✅
- Lines 241-280: NGINX Ingress ✅
- Lines 282-330: Longhorn partial ⚠️ (stopped at CSI check)

**Lines NOT Executed**:
- Lines 331+: All remaining service deployments

---

## PRIORITY FIXES FOR NEXT SESSION

### Priority 1: CRITICAL - Kubeconfig Setup Not Working

**Current Code** (lines 137-144):
```bash
# Configure kubectl for SSH user (k8sadmin)
log_info "Configuring kubectl for ${SSH_USER:-k8sadmin} user"
if [ -n "${SSH_USER}" ] && [ "${SSH_USER}" != "root" ]; then
    mkdir -p /home/${SSH_USER}/.kube
    cp -f /etc/kubernetes/admin.conf /home/${SSH_USER}/.kube/config
    chown ${SSH_USER}:${SSH_USER} /home/${SSH_USER}/.kube/config
    log_success "kubectl configured for ${SSH_USER}"
fi
```

**Problem**: This code appears to never execute

**Investigation Steps**:
1. Check if bootstrap reached line 137
2. Verify SSH_USER environment variable is set by cloud-init
3. Check bootstrap log for "Configuring kubectl" message
4. Verify kubeadm init completed before this section

**Possible Fix**:
Move kubeconfig setup to cloud-init runcmd section as fallback:
```yaml
runcmd:
  # ... existing commands ...
  - /opt/bootstrap/node1-init.sh 2>&1 | tee -a /var/log/cloud-init-output.log

  # Fallback kubeconfig setup (in case bootstrap fails)
  - |
    if [ ! -f /home/k8sadmin/.kube/config ] && [ -f /etc/kubernetes/admin.conf ]; then
      mkdir -p /home/k8sadmin/.kube
      cp -f /etc/kubernetes/admin.conf /home/k8sadmin/.kube/config
      chown k8sadmin:k8sadmin /home/k8sadmin/.kube/config
    fi
```

### Priority 2: HIGH - Longhorn CSI Deployment Check

**Current Code** (approximate line 310):
```bash
log_info "Waiting for CSI components..."
log_info "Waiting for deployment csi-provisioner in longhorn-system"
# Fails here with NotFound error
```

**Fix Required**: Check actual Longhorn deployment names
```bash
# Correct check should be:
log_info "Waiting for Longhorn driver deployer..."
wait_for_deployment longhorn-system longhorn-driver-deployer 300

# Or skip CSI check entirely and verify storage class:
log_info "Verifying Longhorn storage class..."
kubectl get storageclass longhorn
```

**Location**: bootstrap/node1-init.sh around line 310

### Priority 3: MEDIUM - Bootstrap Completion Verification

**Add to end of bootstrap**:
```bash
# Before exit 0
log_info "=== BOOTSTRAP COMPLETION SUMMARY ==="
log_info "Kubernetes: $(kubectl get nodes -o wide | tail -1)"
log_info "Pods Running: $(kubectl get pods -A --no-headers | grep Running | wc -l)"
log_info "Services with External IPs: $(kubectl get svc -A -o wide | grep LoadBalancer | wc -l)"
log_success "Bootstrap completed successfully at $(date)"
```

---

## FILES MODIFIED THIS SESSION

### Bootstrap Script Updated
**File**: [bootstrap/node1-init.sh](/POOL01/software/projects/osbuild/bootstrap/node1-init.sh)

**Changes Applied**:
1. Lines 137-144: Added kubeconfig setup for SSH_USER (NOT WORKING - needs investigation)
2. Lines 167-179: Added Flannel CNI symlink creation (WORKING ✅)
3. Lines 215-239: MetalLB config already present (WORKING ✅)

**Status**: Partially working - 1/2 new fixes operational

### Base Image Configuration
**File**: [config/base-images.conf](/POOL01/software/projects/osbuild/config/base-images.conf)
- Line 28: `X64_TARGET_SIZE="40G"` ✅ Working

### Image Symlink
**File**: output-x64/k8s-x64-latest.img
- Updated to point to k8s-x64-20251106-152421.img (40GB) ✅ Working

---

## CHECKLIST FOR NEXT SESSION

### Immediate Actions
- [ ] SSH into 192.168.100.11 and check `/var/log/bootstrap.log` for:
  - [ ] "Configuring kubectl" message (to see if line 137 executed)
  - [ ] SSH_USER variable value
  - [ ] Error messages before Longhorn deployment
  - [ ] Complete bootstrap log (grep ERROR, FAIL, exit)

- [ ] Check environment variables in bootstrap:
  ```bash
  grep "SSH_USER" /var/log/cloud-init-output.log
  grep "SSH_USER" /var/log/bootstrap.log
  ```

- [ ] Verify Longhorn actual deployment names:
  ```bash
  sudo kubectl get deployments -n longhorn-system
  sudo kubectl get daemonsets -n longhorn-system
  ```

- [ ] Check bootstrap completion markers:
  ```bash
  ls -la /opt/bootstrap/.complete/
  cat /opt/bootstrap/.complete/k8s-init
  ```

### Required Fixes

#### Fix #1 Revision: Kubeconfig Setup
- [ ] Investigate why kubeconfig code didn't execute
- [ ] Determine if SSH_USER is set during bootstrap
- [ ] Add fallback kubeconfig setup to cloud-init runcmd
- [ ] Test with hardcoded username if variable is issue
- [ ] Consider moving kubeconfig to systemd service (after bootstrap)

#### Fix #4: Longhorn CSI Check
- [ ] Identify correct Longhorn CSI deployment names in v1.7.2
- [ ] Update bootstrap wait logic for correct deployment name
- [ ] OR: Skip CSI wait and verify storage class instead
- [ ] Test Longhorn deployment completes successfully

#### Fix #5: Bootstrap Error Handling
- [ ] Add error handling to prevent silent failures
- [ ] Add completion verification at end of bootstrap
- [ ] Log all environment variables at bootstrap start
- [ ] Add set -euo pipefail to fail on errors (carefully)

### Testing Plan
1. [ ] Fix kubeconfig issue (Fix #1 revision)
2. [ ] Fix Longhorn CSI check (Fix #4)
3. [ ] Re-customize node1 image with updated bootstrap
4. [ ] Deploy fresh VM and test complete zero-touch
5. [ ] Monitor for full deployment (all 7 steps)
6. [ ] Verify all services accessible via VIP 192.168.1.30
7. [ ] Document any additional issues discovered

### Success Criteria
- [ ] kubectl works for k8sadmin user without manual intervention
- [ ] All 7 bootstrap steps complete successfully:
  1. [x] Kubernetes init
  2. [ ] Kubectl configuration (currently failing)
  3. [x] Flannel CNI
  4. [x] MetalLB
  5. [x] NGINX Ingress
  6. [ ] Longhorn (currently partial)
  7. [ ] Prometheus + Grafana
  8. [ ] MinIO
  9. [ ] Portainer
  10. [ ] Welcome Page

- [ ] Zero manual intervention required
- [ ] All pods running after bootstrap
- [ ] All services accessible via VIP
- [ ] Bootstrap log shows "COMPLETE" message

---

## PROVEN WORKING FIXES

### Fix #2: Flannel CNI Symlink ✅ VERIFIED
**Status**: Working autonomously in production deployment
**Evidence**: Bootstrap log shows `[SUCCESS] 00:44:17 Flannel symlink created`
**Location**: [bootstrap/node1-init.sh:167-179](/POOL01/software/projects/osbuild/bootstrap/node1-init.sh#L167-L179)
**Impact**: Enables all pod networking, MetalLB, and ingress controllers

### Fix #3: MetalLB Configuration ✅ VERIFIED
**Status**: Working autonomously in production deployment
**Evidence**: VIP 192.168.1.30 assigned to NGINX Ingress LoadBalancer
**Location**: [bootstrap/node1-init.sh:215-239](/POOL01/software/projects/osbuild/bootstrap/node1-init.sh#L215-L239)
**Impact**: Enables external access to cluster services

### Fix #0: 40GB Disk ✅ VERIFIED
**Status**: Working
**Evidence**: VM shows `/dev/vda1 40G 3.1G 35G 9%`
**Location**: [config/base-images.conf:28](/POOL01/software/projects/osbuild/config/base-images.conf#L28)

### Fix #-1: DNS Automation ✅ VERIFIED
**Status**: Working (from previous session)
**Evidence**: DNS resolution working without manual resolvectl
**Location**: [customize-images.sh:302-378](/POOL01/software/projects/osbuild/customize-images.sh#L302-L378)

---

**Document created**: 2025-11-07 00:15:00 UTC
**Last updated**: 2025-11-07 00:55:00 UTC
**Session**: Continuation of 115k token debugging session
**Status**: 2/3 critical fixes working, 2 new issues discovered
**Next step**: Investigate kubeconfig failure and fix Longhorn CSI check
