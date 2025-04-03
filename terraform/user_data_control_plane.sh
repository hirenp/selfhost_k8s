#!/bin/bash
set -e

# Set hostname with instance ID for guaranteed uniqueness
# Get a token for IMDSv2
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
# Use the token to get the instance ID
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
# Extract just the last part of the instance ID to keep hostname shorter
SHORT_ID=$(echo $INSTANCE_ID | cut -d'-' -f2 | cut -c1-8)
HOSTNAME="k8s-control-plane-$SHORT_ID"
echo "Setting hostname to $HOSTNAME"
hostnamectl set-hostname $HOSTNAME
# Add hostname to /etc/hosts
echo "127.0.0.1 $HOSTNAME" >> /etc/hosts
echo "I am control plane node with hostname $HOSTNAME (instance ID: $INSTANCE_ID)"

# Set up SSH key for node-to-node communication
mkdir -p /home/ubuntu/.ssh

# Add public key to authorized_keys for incoming connections
echo "SSH_KEY_PLACEHOLDER" >> /home/ubuntu/.ssh/authorized_keys

# Create the private key file for outgoing connections
cat <<EOF > /home/ubuntu/.ssh/id_rsa
PRIVATE_KEY_PLACEHOLDER
EOF

# Set correct ownership and permissions
chown -R ubuntu:ubuntu /home/ubuntu/.ssh
chmod 700 /home/ubuntu/.ssh
chmod 600 /home/ubuntu/.ssh/authorized_keys
chmod 600 /home/ubuntu/.ssh/id_rsa

# Create a simple SSH config file to avoid host key checking between nodes
cat <<EOF > /home/ubuntu/.ssh/config
Host 10.0.*.*
    StrictHostKeyChecking no
    UserKnownHostsFile=/dev/null
EOF
chmod 600 /home/ubuntu/.ssh/config

# Configure system settings for Kubernetes
cat <<EOK | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOK

modprobe overlay
modprobe br_netfilter

# Set required sysctl params
cat <<EOK | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOK

sysctl --system

# Install dependencies
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release unzip \
  socat conntrack ebtables ethtool iptables netcat-openbsd jq

# Install AWS CLI v2 using the official installer
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

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

# Install kubeadm, kubelet, kubectl using binary downloads
export KUBE_VERSION=1.29.3
export ARCH=amd64

# Download binaries directly
mkdir -p /usr/local/bin
cd /tmp

# Download kubectl
curl -LO "https://dl.k8s.io/release/v${KUBE_VERSION}/bin/linux/${ARCH}/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/

# Download kubeadm
curl -LO "https://dl.k8s.io/release/v${KUBE_VERSION}/bin/linux/${ARCH}/kubeadm"
chmod +x kubeadm
mv kubeadm /usr/local/bin/

# Download kubelet
curl -LO "https://dl.k8s.io/release/v${KUBE_VERSION}/bin/linux/${ARCH}/kubelet"
chmod +x kubelet
mv kubelet /usr/local/bin/

# Download CNI plugins
CNI_VERSION="v1.4.0"
curl -LO "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz"
mkdir -p /opt/cni/bin /etc/cni/net.d
chmod 755 /opt/cni/bin /etc/cni/net.d
tar -C /opt/cni/bin -xzf "cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz"
rm -f "cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz"

# Download crictl
CRICTL_VERSION="v1.29.0"
curl -LO "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz"
tar -zxvf "crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz" -C /usr/local/bin
rm -f "crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz"

# Setup kubelet systemd service
mkdir -p /etc/systemd/system/kubelet.service.d
mkdir -p /var/lib/kubelet
mkdir -p /etc/kubernetes

# Create default kubelet config
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
  webhook:
    cacheAuthorizedTTL: 0s
    cacheUnauthorizedTTL: 0s
cgroupDriver: systemd
cgroupsPerQOS: true
clusterDNS:
- 10.96.0.10
clusterDomain: cluster.local
containerLogMaxSize: 100Mi
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
cpuManagerReconcilePeriod: 0s
evictionPressureTransitionPeriod: 0s
fileCheckFrequency: 0s
healthzBindAddress: 127.0.0.1
healthzPort: 10248
httpCheckFrequency: 0s
imageMinimumGCAge: 0s
logging:
  flushFrequency: 0
  options:
    json:
      infoBufferSize: "0"
  verbosity: 0
memorySwap: {}
nodeStatusReportFrequency: 0s
nodeStatusUpdateFrequency: 0s
resolvConf: /run/systemd/resolve/resolv.conf
rotateCertificates: true
runtimeRequestTimeout: 0s
shutdownGracePeriod: 0s
shutdownGracePeriodCriticalPods: 0s
staticPodPath: /etc/kubernetes/manifests
streamingConnectionIdleTimeout: 0s
syncFrequency: 0s
volumeStatsAggPeriod: 0s
EOF

cat <<EOF | tee /etc/systemd/system/kubelet.service
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target containerd.service
After=network-online.target containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \
  --config=/var/lib/kubelet/config.yaml \
  --container-runtime-endpoint=unix:///run/containerd/containerd.sock \
  --kubeconfig=/etc/kubernetes/kubelet.conf \
  --hostname-override=${HOSTNAME} \
  --node-ip=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN_AGAIN" http://169.254.169.254/latest/meta-data/local-ipv4) \
  --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
  --fail-swap-on=false
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Create missing directories and files to prevent errors
mkdir -p /etc/kubernetes/pki
mkdir -p /etc/kubernetes/manifests
touch /etc/kubernetes/kubelet.conf

# Enable kubelet
systemctl daemon-reload
systemctl enable kubelet

# We don't start kubelet here - it will be started by kubeadm
# This avoids errors until kubeadm sets up the required files

# Create a flag to indicate we've completed the installation
touch /tmp/k8s-prereqs-installed

# Wait for LB to be ready before initializing the first control plane node
# For control-plane-1, initialize the cluster

# Get token for IMDSv2
TOKEN_AGAIN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Get private IP address
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN_AGAIN" http://169.254.169.254/latest/meta-data/local-ipv4)

# Get all control plane IPs directly
CONTROL_PLANE_ASG_NAME="k8s-control-plane-asg"
CONTROL_PLANE_IPS=$(/usr/local/bin/aws ec2 describe-instances --region AWS_REGION_PLACEHOLDER \
  --filters "Name=tag:aws:autoscaling:groupName,Values=$CONTROL_PLANE_ASG_NAME" "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].PrivateIpAddress" --output text)

echo "Found control plane IPs: $CONTROL_PLANE_IPS"

# Sort IPs to determine first node - the lowest IP will be the primary
SORTED_IPS=$(echo $CONTROL_PLANE_IPS | tr ' ' '\n' | sort | tr '\n' ' ')
FIRST_IP=$(echo $SORTED_IPS | cut -d' ' -f1)

echo "Lowest control plane IP is $FIRST_IP, my IP is $PRIVATE_IP"

# Wait for timeout
sleep 30

if [ "$PRIVATE_IP" = "$FIRST_IP" ]; then
  echo "I am the first control plane node, initializing the cluster"
  # Wait for LB to be ready
  sleep 60
  
  # Initialize the cluster with the load balancer endpoint for Calico networking
  kubeadm init --control-plane-endpoint="LOAD_BALANCER_DNS_PLACEHOLDER:6443" \
    --upload-certs \
    --pod-network-cidr=10.244.0.0/16 \
    --node-name=$HOSTNAME \
    --ignore-preflight-errors=Swap,NumCPU \
    --v=5 > /tmp/kubeadm-init.log 2>&1 || {
      echo "First kubeadm init attempt failed, checking logs..."
      tail -30 /tmp/kubeadm-init.log
      echo "Resetting and trying again..."
      kubeadm reset -f
      
      # Second attempt with more debugging - for Calico networking
      echo "Second attempt with more verbose output..."
      kubeadm init --control-plane-endpoint="LOAD_BALANCER_DNS_PLACEHOLDER:6443" \
        --upload-certs \
        --pod-network-cidr=10.244.0.0/16 \
        --node-name=$HOSTNAME \
        --ignore-preflight-errors=all \
        --v=10 > /tmp/kubeadm-init-2.log 2>&1
    }
  
  # Set up kubeconfig for root
  mkdir -p /root/.kube
  cp -i /etc/kubernetes/admin.conf /root/.kube/config
  chown root:root /root/.kube/config
  
  # Also set up kubeconfig for ubuntu user
  mkdir -p /home/ubuntu/.kube
  cp -i /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
  chown ubuntu:ubuntu /home/ubuntu/.kube/config
  
  # Install Calico CNI 
  kubectl --kubeconfig=/root/.kube/config create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml
  
  # Apply Calico configuration
  kubectl --kubeconfig=/root/.kube/config apply -f - <<EOF
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: 10.244.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
EOF
  
  # Extract join command for other nodes
  JOIN_CMD=$(kubeadm token create --print-join-command)
  echo "$JOIN_CMD" > /tmp/kubeadm-join-command.sh
  chmod +x /tmp/kubeadm-join-command.sh
  
  # Extract certificate key for control plane join
  CERT_KEY=$(kubeadm init phase upload-certs --upload-certs | tail -1)
  echo "$CERT_KEY" > /tmp/kubeadm-cert-key.txt

  # Make these files readable by everyone to avoid permission issues during SSH copy
  chmod 644 /tmp/kubeadm-join-command.sh
  chmod 644 /tmp/kubeadm-cert-key.txt
  
  # Create a flag to indicate we've completed the initialization
  touch /tmp/k8s-control-plane-init-complete
else
  # Wait for the first control plane to complete initialization
  echo "I am a secondary control plane node ($HOSTNAME). Waiting for primary to initialize..."
  MAX_WAIT=20
  WAIT_COUNT=0
  
  while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    sleep 15
    WAIT_COUNT=$((WAIT_COUNT+1))
    echo "Waiting for first control plane to initialize (attempt $WAIT_COUNT/$MAX_WAIT)..."
    
    # Try to copy the file from the primary node if it's available
    if nc -z -w 5 $FIRST_IP 22; then
      echo "First control plane node is up, checking for join files..."
      # Try to fetch join command with SCP
      scp -i /home/ubuntu/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$FIRST_IP:/tmp/kubeadm-join-command.sh /tmp/ 2>/dev/null && \
      scp -i /home/ubuntu/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$FIRST_IP:/tmp/kubeadm-cert-key.txt /tmp/ 2>/dev/null && \
      break
    else
      echo "First control plane node ($FIRST_IP) not accessible yet..."
    fi
  done
  
  # Check if we have the join command
  if [ ! -f /tmp/kubeadm-join-command.sh ] || [ ! -f /tmp/kubeadm-cert-key.txt ]; then
    echo "Could not get join command after waiting. Trying alternate methods..."
    # Try to generate join command directly
    kubeadm reset -f
    sleep 5
    
    # Join this node as an additional control plane using the load balancer
    LOAD_BALANCER="LOAD_BALANCER_DNS_PLACEHOLDER"
    echo "Creating a new bootstrap token and joining via load balancer $LOAD_BALANCER"
    
    # Create a bootstrap token
    BOOTSTRAP_TOKEN=$(openssl rand -hex 6 | tr -d '\n' | fold -w 6 | paste -sd '.' -)
    echo "Using bootstrap token: $BOOTSTRAP_TOKEN"
    
    kubeadm join $LOAD_BALANCER:6443 \
      --token $BOOTSTRAP_TOKEN \
      --discovery-token-unsafe-skip-ca-verification \
      --control-plane \
      --node-name=$HOSTNAME \
      --v=5
  else
    # Join this node as an additional control plane
    JOIN_CMD=$(cat /tmp/kubeadm-join-command.sh)
    CERT_KEY=$(cat /tmp/kubeadm-cert-key.txt)
    echo "Joining cluster with: $JOIN_CMD --control-plane --certificate-key $CERT_KEY --node-name $HOSTNAME"
    
    # First reset any previous state to ensure a clean join
    echo "Resetting any previous Kubernetes state before joining..."
    kubeadm reset -f
    
    # Clean up any residual files that might cause join to fail
    rm -f /etc/kubernetes/kubelet.conf
    rm -f /etc/kubernetes/pki/ca.crt
    systemctl restart containerd
    
    # Now try to join
    $JOIN_CMD --control-plane --certificate-key $CERT_KEY --node-name $HOSTNAME
  fi
  
  # Set up kubeconfig for root
  mkdir -p /root/.kube
  cp -i /etc/kubernetes/admin.conf /root/.kube/config
  chown root:root /root/.kube/config
  
  # Also set up kubeconfig for ubuntu user
  mkdir -p /home/ubuntu/.kube
  cp -i /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
  chown ubuntu:ubuntu /home/ubuntu/.kube/config
  
  # Create a flag to indicate we've completed the initialization
  touch /tmp/k8s-control-plane-init-complete
fi