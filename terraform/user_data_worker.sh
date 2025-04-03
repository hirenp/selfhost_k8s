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
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sysctl --system

# Install dependencies - non-interactive
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release unzip socat conntrack ebtables ethtool iptables netcat-openbsd jq

# Install AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip && ./aws/install && rm -rf aws awscliv2.zip

# Install NVIDIA drivers
apt-get update 
apt-get install -y linux-headers-$(uname -r) software-properties-common
# Add the NVIDIA CUDA repository
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb
apt-get update

# Install libtinfo5 and libncurses5
cd /tmp
curl -O http://launchpadlibrarian.net/648013231/libtinfo5_6.4-2_amd64.deb
curl -O http://launchpadlibrarian.net/648013227/libncurses5_6.4-2_amd64.deb
dpkg -i libtinfo5_6.4-2_amd64.deb libncurses5_6.4-2_amd64.deb || apt-get install -f -y
cd -

# Install NVIDIA driver and CUDA components
apt-get install -y --no-install-recommends nvidia-driver-535
apt-get install -y --no-install-recommends cuda-cudart-12-1 cuda-libraries-12-1
apt-get install -y --no-install-recommends libcudnn8

# Install containerd
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update && apt-get install -y containerd.io

# Install NVIDIA Container Toolkit
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update && apt-get install -y nvidia-container-toolkit nvidia-container-runtime

# Configure NVIDIA Container Runtime for containerd
nvidia-ctk runtime configure --runtime=containerd
# Create nvidia runtime handler for RuntimeClass
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Add NVIDIA runtime to containerd config
cat > /etc/containerd/config.toml.nvidia << EOF
version = 2
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
    runtime_type = "io.containerd.runc.v2"
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
      SystemdCgroup = true
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
    runtime_type = "io.containerd.runc.v2"
    privileged_without_host_devices = false
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
      SystemdCgroup = true
      BinaryName = "/usr/bin/nvidia-container-runtime"
EOF

# Merge GPU-specific settings into containerd config
mv /etc/containerd/config.toml /etc/containerd/config.toml.bak
cat /etc/containerd/config.toml.bak | sed '/plugins."io.containerd.grpc.v1.cri".containerd.runtimes/,$d' > /etc/containerd/config.toml
cat /etc/containerd/config.toml.nvidia >> /etc/containerd/config.toml
systemctl restart containerd && systemctl enable containerd

# Create the device plugin directory with proper permissions
mkdir -p /var/lib/kubelet/device-plugins
chmod 750 /var/lib/kubelet/device-plugins

# Setup directories required for Calico CNI
mkdir -p /var/run/calico
mkdir -p /var/lib/calico
chmod 755 /var/run/calico /var/lib/calico

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
mkdir -p /opt/cni/bin /etc/cni/net.d
chmod 755 /opt/cni/bin /etc/cni/net.d
tar -C /opt/cni/bin -xzf "cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz" 
rm -f "cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz"

# Install crictl
CRICTL_VERSION="v1.29.0"
curl -sLO "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz"
tar -zxf "crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz" -C /usr/local/bin && rm -f "crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz"

# Setup kubelet
mkdir -p /etc/systemd/system/kubelet.service.d /var/lib/kubelet /etc/kubernetes/pki /etc/kubernetes/manifests

# Create kubelet config with minimal content
mkdir -p /var/lib/kubelet
cat <<EOF > /var/lib/kubelet/config.yaml
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 0s
    enabled: true
authorization:
  mode: AlwaysAllow
cgroupDriver: systemd
cgroupsPerQOS: true
clusterDomain: cluster.local
clusterDNS:
- 10.96.0.10
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
failSwapOn: false
runtimeRequestTimeout: 15m
EOF

# Ensure config file exists and has correct permissions
ls -la /var/lib/kubelet/config.yaml || echo "Failed to create kubelet config file"
chmod 600 /var/lib/kubelet/config.yaml

# Create kubelet service file
cat <<EOF > /etc/systemd/system/kubelet.service
[Unit]
Description=kubelet: The Kubernetes Node Agent
Wants=network-online.target containerd.service
After=network-online.target containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet --config=/var/lib/kubelet/config.yaml --kubeconfig=/etc/kubernetes/kubelet.conf --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --node-ip=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Setup bootstrap config
CONTROL_PLANE_LB="LOAD_BALANCER_DNS_PLACEHOLDER"
mkdir -p /etc/kubernetes
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
chmod 600 /etc/kubernetes/bootstrap-kubelet.conf

# We'll use the bootstrap token from the join command later
touch /etc/kubernetes/kubelet.conf
chmod 600 /etc/kubernetes/kubelet.conf

# Verify required files exist
[ -f /etc/kubernetes/kubelet.conf ] || echo "kubelet.conf does not exist"
[ -f /etc/kubernetes/bootstrap-kubelet.conf ] || echo "bootstrap-kubelet.conf does not exist"
[ -f /var/lib/kubelet/config.yaml ] || echo "kubelet config.yaml does not exist"

# Only enable kubelet for now, don't start it yet
# We'll start it after joining the cluster
systemctl daemon-reload 
systemctl enable kubelet

# Get join command from control plane nodes with fresh token
CONTROL_PLANE_ASG_NAME="k8s-control-plane-asg"
MAX_WAIT=30
WAIT_COUNT=0

# Wait for API server to be available
echo "Waiting for control plane API..."
while ! nc -z $CONTROL_PLANE_LB 6443 && [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  echo "Waiting for control plane API (attempt $WAIT_COUNT/$MAX_WAIT)..."
  sleep 30
  WAIT_COUNT=$((WAIT_COUNT+1))
done

# Get control plane IPs
CONTROL_PLANE_IPS=$(/usr/local/bin/aws ec2 describe-instances --region AWS_REGION_PLACEHOLDER \
  --filters "Name=tag:aws:autoscaling:groupName,Values=$CONTROL_PLANE_ASG_NAME" "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].PrivateIpAddress" --output text)

# Create script to generate a fresh join command
cat > /tmp/generate_join_command.sh << 'EOF'
#!/bin/bash
# Generate a join command with a new token
CLUSTER_JOIN_COMMAND=$(sudo kubeadm token create --print-join-command)
echo "$CLUSTER_JOIN_COMMAND"
EOF
chmod +x /tmp/generate_join_command.sh

# Try to get fresh join command from a control plane node
JOIN_COMMAND=""
for IP in $CONTROL_PLANE_IPS; do
  if nc -z -w 5 $IP 22; then
    echo "Trying to get fresh join token from control plane node $IP" > /tmp/join-command-attempt-$IP.log
    # Copy script to control plane
    scp -i /home/ubuntu/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 /tmp/generate_join_command.sh ubuntu@$IP:/tmp/generate_join_command.sh 2>/dev/null || continue
    
    # Run the script on control plane
    JOIN_COMMAND=$(ssh -i /home/ubuntu/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$IP "bash /tmp/generate_join_command.sh" 2>/dev/null || echo "")
    echo "Join command from $IP: $JOIN_COMMAND" >> /tmp/join-command-attempt-$IP.log
    
    if [ ! -z "$JOIN_COMMAND" ]; then
      echo "Successfully got join command from $IP" >> /tmp/join-command-attempt-$IP.log
      break
    fi
  fi
done

# If no join command, use a fallback
if [ -z "$JOIN_COMMAND" ]; then
  JOIN_COMMAND="kubeadm join $CONTROL_PLANE_LB:6443 --token abcdef.0123456789abcdef --discovery-token-unsafe-skip-ca-verification --node-name $HOSTNAME"
fi

# Prepare and join the cluster
kubeadm reset -f
systemctl restart containerd

# Join the cluster - this will create proper kubelet.conf with credentials
$JOIN_COMMAND --node-name $HOSTNAME --ignore-preflight-errors=all > /tmp/join-output.log 2>&1 || true

# Fix kubelet configuration if needed
if [ ! -f /etc/kubernetes/kubelet.conf ] && [ -f /etc/kubernetes/bootstrap-kubelet.conf ]; then
  cp /etc/kubernetes/bootstrap-kubelet.conf /etc/kubernetes/kubelet.conf
  chmod 600 /etc/kubernetes/kubelet.conf
fi

# Make sure the kubelet config.yaml exists
if [ ! -f /var/lib/kubelet/config.yaml ]; then
  mkdir -p /var/lib/kubelet
  cat <<EOF > /var/lib/kubelet/config.yaml
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 0s
    enabled: true
authorization:
  mode: AlwaysAllow
cgroupDriver: systemd
cgroupsPerQOS: true
clusterDomain: cluster.local
clusterDNS:
- 10.96.0.10
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
failSwapOn: false
runtimeRequestTimeout: 15m
EOF
  chmod 600 /var/lib/kubelet/config.yaml
fi

# Start kubelet
systemctl daemon-reload
systemctl start kubelet

# Set up port forwarding for ingress NodePorts - non-interactive installation
DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent

# Clear any existing port forwarding rules for 80/443
iptables -t nat -F PREROUTING

# Add new rules at the beginning of the chain
iptables -t nat -I PREROUTING 1 -p tcp --dport 80 -j REDIRECT --to-port 32245
iptables -t nat -I PREROUTING 2 -p tcp --dport 443 -j REDIRECT --to-port 32479

# Make sure these rules are handled before any other rules
iptables -t nat -I PREROUTING 3 -p tcp -j ACCEPT

# Save the rules to persist across reboots
netfilter-persistent save

# Verify the rules
iptables -t nat -L PREROUTING -v --line-numbers > /tmp/iptables-verification.log 2>&1

# Verify Calico networking status and wait for it
echo "Checking for Calico networking readiness..." > /tmp/calico-setup.log

# Give Calico time to initialize network interfaces
counter=0
while [ $counter -lt 10 ] && ! ip link show | grep -E 'cali|tunl'; do
  echo "Waiting for Calico interfaces to appear ($counter/10)..." >> /tmp/calico-setup.log
  sleep 30
  counter=$((counter+1))
done

ip link show | grep -E 'cali|tunl' >> /tmp/calico-setup.log 2>&1
ip addr show | grep -E 'cali|tunl' >> /tmp/calico-setup.log 2>&1

# Ensure iptables rules don't conflict with Calico
echo "Verifying iptables rules compatibility with Calico..." >> /tmp/calico-setup.log
iptables-save | grep -E 'cali|FELIX' >> /tmp/calico-setup.log 2>&1

# Final verification
nvidia-smi > /tmp/nvidia-smi-output.txt 2>&1 || true
touch /tmp/k8s-worker-init-complete