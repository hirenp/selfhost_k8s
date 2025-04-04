#!/bin/bash
set -e

# Set hostname with instance ID for uniqueness in Auto Scaling Group
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
HOSTNAME="k8s-control-plane-$INSTANCE_ID"
hostnamectl set-hostname $HOSTNAME

# Install AWS CLI for instance metadata
apt-get update
apt-get install -y awscli

# Get the instance index from AWS tags or generate a sequential one
NODE_INDEX=$(curl -s http://169.254.169.254/latest/meta-data/ami-launch-index)

# Configure system settings for Kubernetes
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Set required sysctl params
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# Install dependencies
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

# Install containerd
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y containerd.io

# Configure containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# Disable swap
swapoff -a
sed -i '/swap/d' /etc/fstab

# Install kubeadm, kubelet, kubectl
curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | tee /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# Create a flag to indicate we've completed the installation
touch /tmp/k8s-prereqs-installed

# Wait for LB to be ready before initializing the first control plane node
# For control-plane-1, initialize the cluster
if [ "${node_index}" = "1" ]; then
  # Wait for LB to be ready
  sleep 60
  
  # Initialize the cluster with the load balancer endpoint
  # This will be updated with the correct LB DNS name during apply
  kubeadm init --control-plane-endpoint "LOAD_BALANCER_DNS:6443" \
    --upload-certs \
    --pod-network-cidr=10.244.0.0/16 \
    --v=5 > /tmp/kubeadm-init.log 2>&1
  
  # Set up kubeconfig for root
  mkdir -p /root/.kube
  cp -i /etc/kubernetes/admin.conf /root/.kube/config
  chown root:root /root/.kube/config
  
  # Set up Flannel CNI
  kubectl --kubeconfig=/root/.kube/config apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
  
  # Install Metrics Server
  kubectl --kubeconfig=/root/.kube/config apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  
  # Install CoreDNS if not already installed by kubeadm
  kubectl --kubeconfig=/root/.kube/config get deployments -n kube-system coredns >/dev/null 2>&1 || \
    kubectl --kubeconfig=/root/.kube/config apply -f https://raw.githubusercontent.com/coredns/deployment/master/kubernetes/coredns.yaml
  
  # Install Kubernetes Dashboard
  kubectl --kubeconfig=/root/.kube/config apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
  
  # Create Admin Service Account for Dashboard
  cat <<EOF | kubectl --kubeconfig=/root/.kube/config apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF
  
  # Get the token for the admin user
  kubectl --kubeconfig=/root/.kube/config -n kubernetes-dashboard create token admin-user > /tmp/dashboard-admin-token.txt
  
  # Install Helm
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  
  # Add important Helm repositories
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo add jetstack https://charts.jetstack.io
  helm repo update
  
  # Install NGINX Ingress Controller
  helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.service.type=LoadBalancer
    
  # Install cert-manager for SSL/TLS certificate management
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --set installCRDs=true
    
  # Install Prometheus for monitoring
  helm install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --create-namespace \
    --set grafana.enabled=true \
    --set alertmanager.enabled=true
    
  # Create a Prometheus service monitor for Kubernetes components
  cat <<EOF | kubectl --kubeconfig=/root/.kube/config apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kubernetes-components
  namespace: monitoring
  labels:
    release: prometheus
spec:
  endpoints:
  - interval: 30s
    port: https
    scheme: https
    bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
    tlsConfig:
      insecureSkipVerify: true
  selector:
    matchLabels:
      k8s-app: kube-apiserver
  namespaceSelector:
    matchNames:
      - default
      - kube-system
EOF
  
  # Extract join command for other nodes
  kubeadm token create --print-join-command > /tmp/kubeadm-join-command.sh
  kubeadm init phase upload-certs --upload-certs > /tmp/kubeadm-upload-certs.log
  
  # Create a flag to indicate we've completed the initialization
  touch /tmp/k8s-control-plane-init-complete
elif [ "${node_index}" != "1" ]; then
  # Wait for the first control plane to complete initialization
  while [ ! -f /tmp/kubeadm-join-command.sh ]; do
    sleep 10
  done
  
  # Join this node as an additional control plane
  bash /tmp/kubeadm-join-command.sh --control-plane --certificate-key $(tail -1 /tmp/kubeadm-upload-certs.log | awk '{print $3}')
  
  # Set up kubeconfig for root
  mkdir -p /root/.kube
  cp -i /etc/kubernetes/admin.conf /root/.kube/config
  chown root:root /root/.kube/config
  
  # Create a flag to indicate we've completed the initialization
  touch /tmp/k8s-control-plane-init-complete
fi