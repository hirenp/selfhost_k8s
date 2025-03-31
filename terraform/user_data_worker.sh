#!/bin/bash
set -e

# Set hostname with instance ID
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
SHORT_ID=$(echo $INSTANCE_ID | cut -d'-' -f2 | cut -c1-8)
HOSTNAME="k8s-worker-$SHORT_ID"
hostnamectl set-hostname $HOSTNAME
echo "127.0.0.1 $HOSTNAME" >> /etc/hosts

# Set up SSH key
mkdir -p /home/ubuntu/.ssh
echo "SSH_KEY_PLACEHOLDER" >> /home/ubuntu/.ssh/authorized_keys
cat <<EOF > /home/ubuntu/.ssh/id_rsa
PRIVATE_KEY_PLACEHOLDER
EOF
cat <<EOF > /home/ubuntu/.ssh/config
Host 10.0.*.*
    StrictHostKeyChecking no
    UserKnownHostsFile=/dev/null
EOF
chown -R ubuntu:ubuntu /home/ubuntu/.ssh
chmod 700 /home/ubuntu/.ssh
chmod 600 /home/ubuntu/.ssh/authorized_keys /home/ubuntu/.ssh/id_rsa /home/ubuntu/.ssh/config

# Set up Kubernetes prerequisites
cat <<EOK | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOK
modprobe overlay br_netfilter
cat <<EOK | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOK
sysctl --system

# Install dependencies
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release unzip socat conntrack ebtables ethtool iptables netcat-openbsd jq

# Install AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip && ./aws/install && rm -rf aws awscliv2.zip

# Install NVIDIA drivers and CUDA
apt-get update && apt-get install -y linux-headers-$(uname -r) software-properties-common
add-apt-repository -y ppa:graphics-drivers/ppa
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb
apt-get update
apt-get install -y --no-install-recommends cuda-drivers cuda-cudart-12-3 cuda-libraries-12-3 libcudnn9-cuda-12

# Install containerd
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update && apt-get install -y containerd.io
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Install NVIDIA Container Toolkit
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update && apt-get install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=containerd
systemctl restart containerd && systemctl enable containerd

# Setup Kubernetes components
swapoff -a && sed -i '/swap/d' /etc/fstab
export KUBE_VERSION=1.29.3
export ARCH=amd64
mkdir -p /usr/local/bin && cd /tmp

# Download and install Kubernetes binaries
curl -sLO "https://dl.k8s.io/release/v${KUBE_VERSION}/bin/linux/${ARCH}/kubeadm" && chmod +x kubeadm && mv kubeadm /usr/local/bin/
curl -sLO "https://dl.k8s.io/release/v${KUBE_VERSION}/bin/linux/${ARCH}/kubelet" && chmod +x kubelet && mv kubelet /usr/local/bin/

# Install CNI plugins
CNI_VERSION="v1.4.0"
curl -sLO "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz"
mkdir -p /opt/cni/bin && tar -C /opt/cni/bin -xzf "cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz" && rm -f "cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz"

# Install crictl
CRICTL_VERSION="v1.29.0"
curl -sLO "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz"
tar -zxf "crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz" -C /usr/local/bin && rm -f "crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz"

# Setup kubelet 
mkdir -p /etc/systemd/system/kubelet.service.d /var/lib/kubelet /etc/kubernetes/pki /etc/kubernetes/manifests

# Create kubelet config
cat <<EOF > /var/lib/kubelet/config.yaml
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
address: 0.0.0.0
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 0s
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
cgroupDriver: systemd
cgroupsPerQOS: true
clusterDNS:
- 10.96.0.10
clusterDomain: cluster.local
containerLogMaxSize: 100Mi
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
failSwapOn: false
staticPodPath: /etc/kubernetes/manifests
EOF

# Create service file
cat <<EOF > /etc/systemd/system/kubelet.service
[Unit]
Description=kubelet: The Kubernetes Node Agent
Wants=network-online.target containerd.service
After=network-online.target containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet --config=/var/lib/kubelet/config.yaml --kubeconfig=/etc/kubernetes/kubelet.conf --hostname-override=${HOSTNAME} --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Setup bootstrap config
CONTROL_PLANE_LB="LOAD_BALANCER_DNS_PLACEHOLDER"
cat <<EOF > /etc/kubernetes/bootstrap-kubelet.conf
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://${CONTROL_PLANE_LB}:6443
    insecure-skip-tls-verify: true
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: kubelet-bootstrap
  name: bootstrap
current-context: bootstrap
users:
- name: kubelet-bootstrap
  user:
    token: "123456.bootstrap-token-dummy"
EOF
cp /etc/kubernetes/bootstrap-kubelet.conf /etc/kubernetes/kubelet.conf

# Enable kubelet
systemctl daemon-reload && systemctl enable kubelet
touch /tmp/k8s-prereqs-installed

# Wait for control plane and join the cluster
CONTROL_PLANE_ASG_NAME="k8s-control-plane-asg"
MAX_WAIT=30
WAIT_COUNT=0

# Wait for API server to be available
while ! nc -z $CONTROL_PLANE_LB 6443 && [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  echo "Waiting for control plane API (attempt $WAIT_COUNT/$MAX_WAIT)..."
  sleep 30
  WAIT_COUNT=$((WAIT_COUNT+1))
done

# Get control plane IPs
CONTROL_PLANE_IPS=$(/usr/local/bin/aws ec2 describe-instances --region AWS_REGION_PLACEHOLDER \
  --filters "Name=tag:aws:autoscaling:groupName,Values=$CONTROL_PLANE_ASG_NAME" "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].PrivateIpAddress" --output text)

# Try to get join command from each control plane
JOIN_COMMAND=""
for IP in $CONTROL_PLANE_IPS; do
  if nc -z -w 5 $IP 22; then
    scp -i /home/ubuntu/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$IP:/tmp/kubeadm-join-command.sh /tmp/join-command.txt 2>/dev/null || true
    if [ -f /tmp/join-command.txt ] && [ -s /tmp/join-command.txt ]; then
      JOIN_COMMAND=$(cat /tmp/join-command.txt)
      break
    fi
    ssh -i /home/ubuntu/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$IP "cat /tmp/kubeadm-join-command.sh" > /tmp/join-command.txt 2>/dev/null || true
    JOIN_COMMAND=$(cat /tmp/join-command.txt)
    [ ! -z "$JOIN_COMMAND" ] && break
  fi
done

# If no join command, create one with API server
if [ -z "$JOIN_COMMAND" ]; then
  JOIN_COMMAND="kubeadm join $CONTROL_PLANE_LB:6443 --discovery-token-unsafe-skip-ca-verification --node-name $HOSTNAME"
fi

# Prepare and join the cluster
kubeadm reset -f
systemctl restart containerd

# Remove existing bootstrap file to avoid conflicts
rm -f /etc/kubernetes/bootstrap-kubelet.conf
rm -f /etc/kubernetes/kubelet.conf
rm -f /etc/kubernetes/pki/ca.crt
  
# Create bootstrap file for initial kubelet startup
cat > /etc/kubernetes/bootstrap-kubelet.conf <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://${CONTROL_PLANE_LB}:6443
    insecure-skip-tls-verify: true
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: kubelet-bootstrap
  name: bootstrap
current-context: bootstrap
users:
- name: kubelet-bootstrap
  user:
    token: "123456.bootstrap-token-dummy"
EOF
chmod 600 /etc/kubernetes/bootstrap-kubelet.conf

# Join the cluster with ignore-preflight-errors
$JOIN_COMMAND --node-name $HOSTNAME --ignore-preflight-errors=all
touch /tmp/k8s-worker-init-complete
