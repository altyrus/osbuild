#!/bin/bash
################################################################################
# Node 1 Initialization Bootstrap
#
# This script runs on first boot of node1 and performs complete cluster
# initialization with all services.
#
# Timeline: ~15-20 minutes for complete deployment
################################################################################

# Source common library
source /opt/bootstrap/lib/bootstrap-common.sh

log_header "NODE 1 INITIALIZATION STARTING"

################################################################################
# STEP 1: Network Configuration
################################################################################

if ! skip_if_complete "network"; then
    log_step "1" "Configuring Network"

    # These variables will be injected by cloud-init
    # But we can also read from environment
    PRIVATE_IP="${NODE1_PRIVATE_IP:-192.168.100.11}"
    EXTERNAL_IP="${NODE1_EXTERNAL_IP:-192.168.1.21}"
    PRIVATE_NETMASK="${PRIVATE_NETMASK:-24}"
    EXTERNAL_NETMASK="${EXTERNAL_NETMASK:-24}"
    GATEWAY="${PRIVATE_GATEWAY:-192.168.100.1}"
    INTERFACE="${NETWORK_INTERFACE:-eth0}"

    log_info "Network configuration:"
    log_info "  Interface: $INTERFACE"
    log_info "  Private IP: $PRIVATE_IP/$PRIVATE_NETMASK"
    log_info "  External IP: $EXTERNAL_IP/$EXTERNAL_NETMASK"
    log_info "  Gateway: $GATEWAY"

    # Network should already be configured by cloud-init
    # But verify and test
    test_network || die "Network test failed"

    mark_complete "network"
fi

################################################################################
# STEP 2: System Prerequisites
################################################################################

if ! skip_if_complete "prerequisites"; then
    log_step "2" "Verifying System Prerequisites"

    # Disable swap (should already be disabled)
    disable_swap

    # Configure kernel modules
    configure_kernel_modules

    # Configure sysctl
    configure_sysctl

    # Ensure containerd is running
    ensure_service_running containerd

    # Ensure kubelet is enabled (will start after kubeadm init)
    systemctl enable kubelet 2>&1 | tee -a "$BOOTSTRAP_LOG"

    mark_complete "prerequisites"
fi

################################################################################
# STEP 3: Kubernetes Cluster Initialization
################################################################################

if ! skip_if_complete "k8s-init"; then
    log_step "3" "Initializing Kubernetes Cluster"

    # kubeadm init configuration
    log_info "Creating kubeadm config"
    cat > /tmp/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $PRIVATE_IP
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  kubeletExtraArgs:
    node-ip: $PRIVATE_IP
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION:-1.28.0}
controlPlaneEndpoint: "$PRIVATE_IP:6443"
networking:
  podSubnet: ${POD_CIDR:-10.244.0.0/16}
  serviceSubnet: ${SERVICE_CIDR:-10.96.0.0/12}
apiServer:
  certSANs:
    - $PRIVATE_IP
    - ${EXTERNAL_IP}
    - ${VIP:-192.168.1.100}
    - $(hostname)
controllerManager:
  extraArgs:
    bind-address: "0.0.0.0"
scheduler:
  extraArgs:
    bind-address: "0.0.0.0"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF

    log_info "Initializing cluster (this takes 3-5 minutes)..."
    timeout 600 kubeadm init \
        --config /tmp/kubeadm-config.yaml \
        --upload-certs 2>&1 | tee -a "$BOOTSTRAP_LOG"

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        die "kubeadm init failed"
    fi

    log_success "Kubernetes cluster initialized"

    # Setup kubeconfig
    mkdir -p $HOME/.kube
    cp /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config

    # Also copy to bootstrap directory for other scripts
    cp /etc/kubernetes/admin.conf /opt/bootstrap/kubeconfig
    chmod 644 /opt/bootstrap/kubeconfig

    export KUBECONFIG=/etc/kubernetes/admin.conf

    # Configure kubectl for SSH user (k8sadmin)
    # Use fallback to k8sadmin if SSH_USER not set
    KUBE_USER="${SSH_USER:-k8sadmin}"
    log_info "Configuring kubectl for ${KUBE_USER} user"
    if [ "${KUBE_USER}" != "root" ] && id "${KUBE_USER}" &>/dev/null; then
        mkdir -p /home/${KUBE_USER}/.kube
        cp -f /etc/kubernetes/admin.conf /home/${KUBE_USER}/.kube/config
        chown ${KUBE_USER}:${KUBE_USER} /home/${KUBE_USER}/.kube/config
        log_success "kubectl configured for ${KUBE_USER}"
    else
        log_warn "User ${KUBE_USER} not found or is root, skipping kubeconfig setup"
    fi

    # Wait for API server to be ready
    wait_for_api_server "localhost:6443"

    # Remove control-plane taint to allow workloads
    log_info "Removing control-plane taint"
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>&1 | tee -a "$BOOTSTRAP_LOG" || true
    kubectl taint nodes --all node-role.kubernetes.io/master- 2>&1 | tee -a "$BOOTSTRAP_LOG" || true

    # Remove exclude-from-external-load-balancers label for single-node clusters
    # This label prevents MetalLB from announcing LoadBalancer services on control-plane nodes
    # In single-node deployments, we MUST allow the control-plane to handle load balancer traffic
    log_info "Removing exclude-from-external-load-balancers label (required for MetalLB)"
    kubectl label nodes --all node.kubernetes.io/exclude-from-external-load-balancers- 2>&1 | tee -a "$BOOTSTRAP_LOG" || true

    mark_complete "k8s-init"
fi

export KUBECONFIG=/etc/kubernetes/admin.conf

################################################################################
# STEP 4: Deploy CNI (Flannel)
################################################################################

if ! skip_if_complete "cni"; then
    log_step "4" "Deploying Flannel CNI"

    apply_manifest_url \
        "https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml" \
        "Flannel CNI"

    log_info "Waiting for Flannel pods to be ready (may take 2-3 minutes)..."
    sleep 30
    wait_for_daemonset kube-flannel kube-flannel-ds 300

    log_success "Flannel CNI deployed and running"

    # Create flannel symlink for containerd
    # Flannel DaemonSet installs to /opt/cni/bin/ but containerd expects plugins in /usr/lib/cni/
    log_info "Creating flannel CNI plugin symlink"
    if [ -f /opt/cni/bin/flannel ] && [ ! -f /usr/lib/cni/flannel ]; then
        ln -sf /opt/cni/bin/flannel /usr/lib/cni/flannel
        log_success "Flannel symlink created"

        # Restart containerd to pick up the new plugin
        systemctl restart containerd
        sleep 5
    else
        log_info "Flannel symlink already exists or flannel binary not found"
    fi

    mark_complete "cni"
fi

################################################################################
# STEP 5: Deploy MetalLB
################################################################################

if ! skip_if_complete "metallb"; then
    log_step "5" "Deploying MetalLB"

    # Deploy MetalLB
    METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"
    apply_manifest_url \
        "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml" \
        "MetalLB ${METALLB_VERSION}"

    log_info "Waiting for MetalLB controller..."
    wait_for_pods metallb-system "app=metallb,component=controller" 300

    log_info "Waiting for MetalLB speaker..."
    wait_for_daemonset metallb-system speaker 300

    log_info "Waiting for webhook initialization (60s buffer)..."
    sleep 60

    # Configure IP pool
    VIP="${VIP:-192.168.1.100}"
    METALLB_IP_RANGE="${METALLB_IP_RANGE:-${VIP}-${VIP}}"

    log_info "Configuring MetalLB IP pool: $METALLB_IP_RANGE"

    cat <<EOF | kubectl apply -f - 2>&1 | tee -a "$BOOTSTRAP_LOG"
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: external-pool
  namespace: metallb-system
spec:
  addresses:
  - $METALLB_IP_RANGE
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: external-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - external-pool
EOF

    log_success "MetalLB deployed with VIP: $VIP"
    mark_complete "metallb"
fi

################################################################################
# STEP 6: Deploy NGINX Ingress Controller
################################################################################

if ! skip_if_complete "ingress"; then
    log_step "6" "Deploying NGINX Ingress Controller"

    INGRESS_VERSION="${INGRESS_NGINX_VERSION:-v1.11.3}"
    apply_manifest_url \
        "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${INGRESS_VERSION}/deploy/static/provider/cloud/deploy.yaml" \
        "NGINX Ingress ${INGRESS_VERSION}"

    log_info "Waiting for admission webhook jobs..."
    sleep 45
    kubectl wait --for=condition=complete job/ingress-nginx-admission-create -n ingress-nginx --timeout=120s 2>&1 | tee -a "$BOOTSTRAP_LOG" || true
    kubectl wait --for=condition=complete job/ingress-nginx-admission-patch -n ingress-nginx --timeout=120s 2>&1 | tee -a "$BOOTSTRAP_LOG" || true

    log_info "Waiting for ingress controller..."
    wait_for_pods ingress-nginx "app.kubernetes.io/component=controller" 180

    log_info "Waiting for LoadBalancer IP assignment..."
    sleep 10

    # Get the external IP
    EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    log_success "NGINX Ingress deployed. External IP: $EXTERNAL_IP"

    mark_complete "ingress"
fi

################################################################################
# STEP 7: Deploy Longhorn Storage
################################################################################

if ! skip_if_complete "longhorn" && [ "${DEPLOY_LONGHORN:-true}" = "true" ]; then
    log_step "7" "Deploying Longhorn Distributed Storage"

    # Ensure prerequisites
    ensure_service_running iscsid
    ensure_service_running open-iscsi || true

    # Create data directory
    LONGHORN_DATA_DIR="${LONGHORN_DATA_DIR:-/var/lib/longhorn}"
    mkdir -p "$LONGHORN_DATA_DIR"
    chmod 755 "$LONGHORN_DATA_DIR"
    log_info "Longhorn data directory: $LONGHORN_DATA_DIR"

    # Deploy Longhorn
    LONGHORN_VERSION="${LONGHORN_VERSION:-v1.7.2}"
    apply_manifest_url \
        "https://raw.githubusercontent.com/longhorn/longhorn/${LONGHORN_VERSION}/deploy/longhorn.yaml" \
        "Longhorn ${LONGHORN_VERSION}"

    log_info "Waiting for Longhorn manager (may take 3-5 minutes)..."
    wait_for_daemonset longhorn-system longhorn-manager 600

    log_info "Waiting for CSI components..."
    # Longhorn v1.7.2 uses longhorn-driver-deployer instead of csi-provisioner
    wait_for_deployment longhorn-system longhorn-driver-deployer 300
    wait_for_daemonset longhorn-system longhorn-csi-plugin 300

    log_info "Waiting for instance managers (extended timeout for image pulls - up to 10 minutes)..."
    sleep 60  # Initial buffer
    wait_for_pods longhorn-system "longhorn.io/component=instance-manager" 600 || log_warn "Some instance managers may still be pulling images"

    # Configure Longhorn settings
    log_info "Configuring Longhorn settings"

    # Set replica count (1 for single node)
    kubectl patch settings.longhorn.io default-replica-count -n longhorn-system \
        --type=merge -p '{"value":"1"}' 2>&1 | tee -a "$BOOTSTRAP_LOG"

    # Set data locality for single node
    kubectl patch settings.longhorn.io default-data-locality -n longhorn-system \
        --type=merge -p '{"value":"best-effort"}' 2>&1 | tee -a "$BOOTSTRAP_LOG"

    # Set default storage class
    log_info "Setting Longhorn as default storage class"
    kubectl patch storageclass longhorn -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>&1 | tee -a "$BOOTSTRAP_LOG"

    # Create Longhorn ingress
    cat <<EOF | kubectl apply -f - 2>&1 | tee -a "$BOOTSTRAP_LOG"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: longhorn-ingress
  namespace: longhorn-system
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /longhorn
        pathType: Prefix
        backend:
          service:
            name: longhorn-frontend
            port:
              number: 80
EOF

    log_success "Longhorn deployed. UI: http://$VIP/longhorn"
    mark_complete "longhorn"
elif [ "${DEPLOY_LONGHORN:-true}" != "true" ]; then
    log_info "Skipping Longhorn (DEPLOY_LONGHORN=false)"
fi

################################################################################
# STEP 8: Deploy MinIO
################################################################################

if ! skip_if_complete "minio" && [ "${DEPLOY_MINIO:-true}" = "true" ]; then
    log_step "8" "Deploying MinIO S3 Storage"

    # Add MinIO Helm repo
    helm_add_repo minio https://charts.min.io/

    # Generate password if not set
    MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)}"

    # Deploy MinIO in standalone mode (single node)
    helm_install minio minio/minio minio-system \
        --set mode=standalone \
        --set persistence.enabled=true \
        --set persistence.storageClass=longhorn \
        --set persistence.size=50Gi \
        --set resources.requests.memory=1Gi \
        --set resources.requests.cpu=250m \
        --set rootUser=${MINIO_ROOT_USER:-admin} \
        --set rootPassword=$MINIO_ROOT_PASSWORD \
        --set service.type=ClusterIP \
        --set consoleService.type=ClusterIP \
        --timeout=10m

    log_info "Waiting for MinIO to be ready..."
    sleep 30
    wait_for_pods minio-system "app=minio" 300

    # Create MinIO ingress
    cat <<EOF | kubectl apply -f - 2>&1 | tee -a "$BOOTSTRAP_LOG"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minio-console
  namespace: minio-system
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /\$2
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /minio(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: minio-console
            port:
              number: 9001
EOF

    # Save credentials
    echo "$MINIO_ROOT_PASSWORD" > /opt/bootstrap/minio-password.txt
    chmod 600 /opt/bootstrap/minio-password.txt

    log_success "MinIO deployed. Console: http://$VIP/minio (admin/$MINIO_ROOT_PASSWORD)"
    mark_complete "minio"
elif [ "${DEPLOY_MINIO:-true}" != "true" ]; then
    log_info "Skipping MinIO (DEPLOY_MINIO=false)"
fi

################################################################################
# STEP 9: Deploy Monitoring (Prometheus + Grafana)
################################################################################

if ! skip_if_complete "monitoring" && [ "${DEPLOY_GRAFANA:-true}" = "true" ]; then
    log_step "9" "Deploying Monitoring Stack"

    # Add Helm repos
    helm_add_repo grafana https://grafana.github.io/helm-charts
    helm_add_repo prometheus-community https://prometheus-community.github.io/helm-charts

    # Deploy Grafana
    log_info "Deploying Grafana..."
    helm_install grafana grafana/grafana monitoring \
        --set adminPassword=${GRAFANA_ADMIN_PASSWORD:-admin} \
        --set service.type=ClusterIP \
        --set persistence.enabled=true \
        --set persistence.storageClassName=longhorn \
        --set persistence.size=10Gi \
        --set "env.GF_SERVER_ROOT_URL=%(protocol)s://%(domain)s/grafana/" \
        --set env.GF_SERVER_SERVE_FROM_SUB_PATH=true \
        --set datasources."datasources\.yaml".apiVersion=1 \
        --set datasources."datasources\.yaml".datasources[0].name=Prometheus \
        --set datasources."datasources\.yaml".datasources[0].type=prometheus \
        --set datasources."datasources\.yaml".datasources[0].access=proxy \
        --set datasources."datasources\.yaml".datasources[0].url=http://prometheus-server.monitoring.svc.cluster.local/prometheus \
        --set datasources."datasources\.yaml".datasources[0].isDefault=true

    sleep 30

    # Deploy Prometheus
    log_info "Deploying Prometheus..."
    helm_install prometheus prometheus-community/prometheus monitoring \
        --set server.prefixURL=/prometheus \
        --set server.baseURL=http://$VIP/prometheus \
        --set server.persistentVolume.enabled=true \
        --set server.persistentVolume.storageClass=longhorn \
        --set server.persistentVolume.size=10Gi \
        --set alertmanager.enabled=false \
        --set prometheus-pushgateway.enabled=false \
        --set kube-state-metrics.enabled=true \
        --set prometheus-node-exporter.enabled=true

    sleep 40

    # Create ingresses
    cat <<EOF | kubectl apply -f - 2>&1 | tee -a "$BOOTSTRAP_LOG"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /grafana
        pathType: Prefix
        backend:
          service:
            name: grafana
            port:
              number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prometheus
  namespace: monitoring
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /prometheus
        pathType: Prefix
        backend:
          service:
            name: prometheus-server
            port:
              number: 80
EOF

    log_success "Monitoring deployed. Grafana: http://$VIP/grafana (admin/${GRAFANA_ADMIN_PASSWORD:-admin})"
    mark_complete "monitoring"
elif [ "${DEPLOY_GRAFANA:-true}" != "true" ]; then
    log_info "Skipping Monitoring (DEPLOY_GRAFANA=false)"
fi

################################################################################
# STEP 10: Deploy Portainer
################################################################################

if ! skip_if_complete "portainer" && [ "${DEPLOY_PORTAINER:-true}" = "true" ]; then
    log_step "10" "Deploying Portainer"

    apply_manifest_url \
        "https://downloads.portainer.io/ce2-19/portainer.yaml" \
        "Portainer"

    sleep 30

    # Patch storage class
    kubectl patch pvc portainer -n portainer -p '{"spec":{"storageClassName":"longhorn"}}' 2>&1 | tee -a "$BOOTSTRAP_LOG" || true

    # Create ingress
    cat <<EOF | kubectl apply -f - 2>&1 | tee -a "$BOOTSTRAP_LOG"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portainer
  namespace: portainer
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /\$2
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /portainer(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: portainer
            port:
              number: 9000
EOF

    log_success "Portainer deployed. UI: http://$VIP/portainer"
    mark_complete "portainer"
elif [ "${DEPLOY_PORTAINER:-true}" != "true" ]; then
    log_info "Skipping Portainer (DEPLOY_PORTAINER=false)"
fi

################################################################################
# STEP 11: Deploy Welcome Page
################################################################################

if ! skip_if_complete "welcome" && [ "${DEPLOY_WELCOME_PAGE:-true}" = "true" ]; then
    log_step "11" "Deploying Welcome Page"

    cat <<EOF | kubectl apply -f - 2>&1 | tee -a "$BOOTSTRAP_LOG"
apiVersion: v1
kind: Namespace
metadata:
  name: welcome
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: welcome-html
  namespace: welcome
data:
  index.html: |
    <!DOCTYPE html>
    <html>
    <head>
        <title>Kubernetes Cluster - Welcome</title>
        <style>
            body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
            .container { max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
            h1 { color: #326ce5; }
            .service { background: #f0f0f0; padding: 15px; margin: 10px 0; border-radius: 4px; }
            .service a { color: #326ce5; text-decoration: none; font-weight: bold; }
            .service a:hover { text-decoration: underline; }
            .info { background: #e7f3ff; padding: 10px; border-left: 4px solid #326ce5; margin: 20px 0; }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>🎉 Zero-Touch Kubernetes Cluster</h1>
            <div class="info">
                <strong>Cluster Status:</strong> Ready<br>
                <strong>VIP:</strong> $VIP<br>
                <strong>Node:</strong> $(hostname)
            </div>

            <h2>Available Services</h2>

            <div class="service">
                <strong>Portainer</strong> - Web-based Kubernetes Management<br>
                <a href="/portainer/" target="_blank">Open Portainer →</a>
            </div>

            <div class="service">
                <strong>Grafana</strong> - Monitoring Dashboards<br>
                <a href="/grafana/" target="_blank">Open Grafana →</a> (admin/admin)
            </div>

            <div class="service">
                <strong>Prometheus</strong> - Metrics and Monitoring<br>
                <a href="/prometheus/" target="_blank">Open Prometheus →</a>
            </div>

            <div class="service">
                <strong>Longhorn</strong> - Distributed Block Storage<br>
                <a href="/longhorn/" target="_blank">Open Longhorn →</a>
            </div>

            <div class="service">
                <strong>MinIO</strong> - S3-Compatible Object Storage<br>
                <a href="/minio/" target="_blank">Open MinIO →</a> (admin/[see logs])
            </div>

            <h2>Quick Start</h2>
            <p>Your Kubernetes cluster is ready to use! All services are deployed and accessible via the VIP.</p>
            <ul>
                <li>Deploy applications using <strong>Portainer</strong></li>
                <li>Monitor cluster health in <strong>Grafana</strong></li>
                <li>Manage storage with <strong>Longhorn</strong></li>
                <li>Store objects in <strong>MinIO</strong></li>
            </ul>

            <div class="info">
                <strong>Bootstrap Log:</strong> /var/log/bootstrap.log<br>
                <strong>Kubeconfig:</strong> /opt/bootstrap/kubeconfig
            </div>
        </div>
    </body>
    </html>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: welcome
  namespace: welcome
spec:
  replicas: 2
  selector:
    matchLabels:
      app: welcome
  template:
    metadata:
      labels:
        app: welcome
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
          limits:
            cpu: 50m
            memory: 32Mi
      volumes:
      - name: html
        configMap:
          name: welcome-html
---
apiVersion: v1
kind: Service
metadata:
  name: welcome
  namespace: welcome
spec:
  selector:
    app: welcome
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: welcome
  namespace: welcome
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: welcome
            port:
              number: 80
EOF

    log_success "Welcome page deployed. Access: http://$VIP/"
    mark_complete "welcome"
elif [ "${DEPLOY_WELCOME_PAGE:-true}" != "true" ]; then
    log_info "Skipping Welcome Page (DEPLOY_WELCOME_PAGE=false)"
fi

################################################################################
# STEP 12: Create Cluster Ready Signal
################################################################################

if ! skip_if_complete "cluster-ready"; then
    log_step "12" "Creating Cluster Ready Signal"

    # Create ConfigMap to signal nodes 2/3 that cluster is ready
    cat <<EOF | kubectl apply -f - 2>&1 | tee -a "$BOOTSTRAP_LOG"
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-ready
  namespace: kube-system
data:
  ready: "true"
  timestamp: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  node: "$(hostname)"
EOF

    log_success "Cluster ready signal created"
    mark_complete "cluster-ready"
fi

################################################################################
# FINAL STEPS
################################################################################

log_header "BOOTSTRAP COMPLETE"
log_success "Kubernetes cluster is fully operational!"
log ""
log "=================================="
log "CLUSTER ACCESS INFORMATION"
log "=================================="
log "VIP: $VIP"
log "Welcome Page: http://$VIP/"
log "Portainer: http://$VIP/portainer/"
log "Grafana: http://$VIP/grafana/ (admin/${GRAFANA_ADMIN_PASSWORD:-admin})"
log "Prometheus: http://$VIP/prometheus/"
log "Longhorn: http://$VIP/longhorn/"
log "MinIO: http://$VIP/minio/ (admin/[see /opt/bootstrap/minio-password.txt])"
log ""
log "Kubeconfig: /opt/bootstrap/kubeconfig"
log "Bootstrap log: $BOOTSTRAP_LOG"
log "=================================="
log ""
log_info "Total bootstrap time: $SECONDS seconds"

# Cleanup bootstrap scripts
if [ "${CLEANUP_BOOTSTRAP:-true}" = "true" ]; then
    cleanup_bootstrap
fi

log_header "NODE 1 INITIALIZATION COMPLETE"

exit 0
