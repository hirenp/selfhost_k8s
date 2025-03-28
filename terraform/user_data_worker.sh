#!/bin/bash
set -e

# Set hostname with instance ID for guaranteed uniqueness
# Get a token for IMDSv2
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
# Use the token to get the instance ID
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
# Extract just the last part of the instance ID to keep hostname shorter
SHORT_ID=$(echo $INSTANCE_ID | cut -d'-' -f2 | cut -c1-8)
HOSTNAME="k8s-worker-$SHORT_ID"
echo "Setting hostname to $HOSTNAME"
hostnamectl set-hostname $HOSTNAME
# Add hostname to /etc/hosts
echo "127.0.0.1 $HOSTNAME" >> /etc/hosts
echo "I am worker node with hostname $HOSTNAME (instance ID: $INSTANCE_ID)"

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

# Install kubeadm, kubelet using binary downloads
export KUBE_VERSION=1.29.3
export ARCH=amd64

# Download binaries directly
mkdir -p /usr/local/bin
cd /tmp

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
mkdir -p /opt/cni/bin
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

# Get control plane IP - we'll get it from the load balancer
CONTROL_PLANE_LB="LOAD_BALANCER_DNS_PLACEHOLDER"

# Wait for first control plane to be ready
echo "Waiting for control plane to initialize (checking load balancer: $CONTROL_PLANE_LB)"
MAX_WAIT=30
WAIT_COUNT=0

while ! nc -z $CONTROL_PLANE_LB 6443 && [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  echo "Waiting for control plane API to be accessible (attempt $WAIT_COUNT/$MAX_WAIT)..."
  sleep 30
  WAIT_COUNT=$((WAIT_COUNT+1))
done

if ! nc -z $CONTROL_PLANE_LB 6443; then
  echo "Warning: Control plane API did not become accessible after waiting. Will try to proceed anyway."
fi

# Additional verification of control plane
echo "Verifying control plane API actually responds to requests..."
if ! curl -k https://$CONTROL_PLANE_LB:6443/healthz; then
  echo "Control plane API is not healthy yet. Will continue trying to join through direct node communication."
fi

# Get the join command from the control plane
echo "Getting join command from control plane"

# Get all control plane IPs directly
CONTROL_PLANE_ASG_NAME="k8s-control-plane-asg"
CONTROL_PLANE_IPS=$(/usr/local/bin/aws ec2 describe-instances --region AWS_REGION_PLACEHOLDER \
  --filters "Name=tag:aws:autoscaling:groupName,Values=$CONTROL_PLANE_ASG_NAME" "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].PrivateIpAddress" --output text)

echo "Found control plane IPs: $CONTROL_PLANE_IPS"

# Get each control plane IP and try to get the join command
JOIN_COMMAND=""
for IP in $CONTROL_PLANE_IPS; do
  echo "Trying control plane at private IP: $IP"
  
  # Check if SSH port is open
  if nc -z -w 5 $IP 22; then
    echo "SSH port is open on IP $IP"
    
    # Try to get the join command with the private key we have
    scp -i /home/ubuntu/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$IP:/tmp/kubeadm-join-command.sh /tmp/join-command.txt 2>/dev/null || true
    
    # Check if we got the file
    if [ -f /tmp/join-command.txt ] && [ -s /tmp/join-command.txt ]; then
      JOIN_COMMAND=$(cat /tmp/join-command.txt)
      echo "Got join command from $IP"
      break
    else
      echo "Failed to get join command via SCP, trying SSH"
      # Try SSH as fallback
      ssh -i /home/ubuntu/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$IP "cat /tmp/kubeadm-join-command.sh" > /tmp/join-command.txt 2>/dev/null || true
      JOIN_COMMAND=$(cat /tmp/join-command.txt)
      
      if [ ! -z "$JOIN_COMMAND" ]; then
        echo "Got join command from $IP via SSH"
        break
      fi
    fi
  else
    echo "SSH port not accessible on IP $IP"
  fi
done

# If we couldn't get the join command, try to generate it ourselves
if [ -z "$JOIN_COMMAND" ]; then
  echo "Could not get join command from any control plane node. Trying to generate a join command."
  
  # Try using kubeadm token create on the API server via the load balancer
  echo "Attempting to create a token directly via the API server"
  TOKEN=$(kubeadm token create 2>/dev/null || echo "")
  
  if [ ! -z "$TOKEN" ]; then
    # Get the CA cert hash from the load balancer
    echo "Token created, getting CA hash"
    CA_HASH=$(openssl s_client -showcerts -connect $CONTROL_PLANE_LB:6443 </dev/null 2>/dev/null | openssl x509 -outform DER | openssl dgst -sha256 -hex | sed 's/^.* //')
    
    if [ ! -z "$CA_HASH" ]; then
      JOIN_COMMAND="kubeadm join $CONTROL_PLANE_LB:6443 --token $TOKEN --discovery-token-ca-cert-hash sha256:$CA_HASH --node-name $HOSTNAME"
      echo "Generated join command: $JOIN_COMMAND"
    fi
  else
    echo "Failed to create token, will try discovery"
    # Last resort - use discovery mode
    JOIN_COMMAND="kubeadm join $CONTROL_PLANE_LB:6443 --discovery-token-unsafe-skip-ca-verification --node-name $HOSTNAME"
  fi
fi

# Final check and join
if [ -z "$JOIN_COMMAND" ]; then
  echo "Failed to get join command after multiple attempts. Cluster may not be ready."
  exit 1
else
  echo "Joining the cluster with: $JOIN_COMMAND --node-name $HOSTNAME"
  
  # Reset any previous Kubernetes state to ensure a clean join
  echo "Resetting any previous Kubernetes state before joining..."
  kubeadm reset -f
  
  # Clean up any residual files that might cause join to fail
  rm -f /etc/kubernetes/kubelet.conf
  rm -f /etc/kubernetes/pki/ca.crt
  systemctl restart containerd
  
  # Ensure we use our specific hostname
  $JOIN_COMMAND --node-name $HOSTNAME
fi

# Create a flag to indicate we've completed the initialization
touch /tmp/k8s-worker-init-complete