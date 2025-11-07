# MetalLB VIP Fix - Critical Issue Resolved

## Issue Summary
MetalLB VIP was not accessible despite correct network configuration, IP allocation, and service setup.

## Root Cause
**The control-plane node had the Kubernetes label `node.kubernetes.io/exclude-from-external-load-balancers=`**

This label instructs MetalLB (and other load balancer controllers) to EXCLUDE the node from handling LoadBalancer services. This is default behavior in Kubernetes for control-plane nodes to prevent them from receiving external traffic.

However, in **single-node clusters**, the control-plane MUST handle load balancer traffic since there are no other nodes available.

## Symptoms
- ✅ MetalLB controller successfully assigns VIP to LoadBalancer services
- ✅ MetalLB speaker pod running and creating ARP responders
- ✅ ARP requests for VIP reaching the VM
- ❌ **NO ServiceL2Status resources created** (smoking gun!)
- ❌ VIP not accessible from external network
- ❌ No ARP announcements from MetalLB speaker

## Investigation Path
1. Verified network connectivity: Physical NIC → Bridge → VM interface ✅
2. Verified MetalLB configuration: IPAddressPool, L2Advertisement ✅
3. Verified service endpoints exist ✅
4. Checked for ServiceL2Status resources → **NONE FOUND** 🎯
5. Discovered node label excluding it from load balancers

## Solution
Remove the label on single-node/control-plane-only clusters:

```bash
kubectl label node <node-name> node.kubernetes.io/exclude-from-external-load-balancers-
```

## Verification
After removing the label:
- ✅ ServiceL2Status resource created immediately
- ✅ MetalLB speaker logs show "service has IP, announcing"
- ✅ ARP table shows VIP → VM MAC address mapping
- ✅ VIP accessible via HTTP/TCP (ICMP may still be dropped)

## Integration into Zero-Touch Deployment
The fix has been added to the Kubernetes bootstrap script at:
`/var/lib/cloud/scripts/per-boot/bootstrap-k8s.sh`

For single-node clusters, after kubeadm init completes, the script now automatically:
1. Checks if only one node exists
2. Removes the `exclude-from-external-load-balancers` label from control-plane nodes
3. Allows MetalLB to announce LoadBalancer service VIPs

## Technical Details

### Why This Label Exists
Kubernetes automatically applies this label to control-plane nodes to:
- Prevent production traffic from impacting cluster management
- Reserve control-plane resources for Kubernetes API server and controllers
- Follow best practices for multi-node clusters

### Why We Override It
In single-node deployments:
- Control-plane IS the only node
- No separate worker nodes available
- MetalLB MUST use the control-plane node or VIPs won't work at all

### Network Architecture (Final Working Configuration)
```
External Network (192.168.1.0/24)
         ↓
   Physical NIC (enp3s0f1)
         ↓
     Linux Bridge (br0)
         ↓
   VM Interface (ens8: 192.168.1.21/24)
         ↓
   MetalLB Speaker (announces VIP 192.168.1.30)
         ↓
   Services accessible at 192.168.1.30
```

## Files Modified
- `ignition/files/bootstrap-k8s.sh` - Added label removal logic
- `METALLB-VIP-FIX.md` - This documentation

## Testing Performed
- ✅ Test LoadBalancer service created
- ✅ VIP assigned by MetalLB controller
- ✅ ServiceL2Status resource created
- ✅ ARP announcements working
- ✅ HTTP traffic to VIP successful
- ✅ Multiple external clients can access services via VIP

## Date Resolved
2025-11-07

## Next Steps
1. Test full deployment with updated bootstrap script
2. Verify ingress-nginx, Grafana, Prometheus accessible via VIP
3. Consider making label removal conditional on `NODE_COUNT=1` in config
