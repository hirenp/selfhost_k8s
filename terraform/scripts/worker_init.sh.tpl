#!/bin/bash
set -e

# Set hostname with instance ID for uniqueness in Auto Scaling Group
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
HOSTNAME="k8s-worker-$INSTANCE_ID"
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

# Install kubeadm, kubelet
curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | tee /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm
apt-mark hold kubelet kubeadm

# Create a flag to indicate we've completed the installation
touch /tmp/k8s-prereqs-installed

# Wait for the first control plane to complete initialization
until ssh -o StrictHostKeyChecking=no k8s-control-plane-1 "test -f /tmp/kubeadm-join-command.sh"; do
  echo "Waiting for control plane initialization to complete..."
  sleep 30
done

# Get the join command from the first control plane node
JOIN_COMMAND=$(ssh -o StrictHostKeyChecking=no k8s-control-plane-1 "cat /tmp/kubeadm-join-command.sh")

# Join the cluster
$JOIN_COMMAND

# Create a flag to indicate we've completed the initialization
touch /tmp/k8s-worker-init-complete

# AWS Load Balancer Target Group Registration
cat > /tmp/register_target_groups.sh << 'EOF'
#!/bin/bash
set -e

# This script registers EC2 instances with AWS Load Balancer target groups
# It is meant to be run after the load balancer service has been created

# Get the AWS region from the instance metadata
AWS_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

# Wait for target groups to be created
sleep 60

# Find target groups containing "ingress" in the name
echo "Looking for ingress target groups in region ${AWS_REGION}..."
TARGET_GROUPS=$(aws elbv2 describe-target-groups --region ${AWS_REGION} --query "TargetGroups[?contains(TargetGroupName, 'ingress')].TargetGroupArn" --output text)

if [ -z "$TARGET_GROUPS" ]; then
  echo "No ingress target groups found. Will retry later."
  exit 0
fi

# For each target group, find its target port from the health check port and register the instance
for TARGET_GROUP_ARN in $TARGET_GROUPS; do
  echo "Processing target group: ${TARGET_GROUP_ARN}"
  
  # Get the port for this target group
  PORT=$(aws elbv2 describe-target-groups --region ${AWS_REGION} --target-group-arns ${TARGET_GROUP_ARN} --query "TargetGroups[0].Port" --output text)
  
  echo "Registering instance ${INSTANCE_ID} on port ${PORT} with target group ${TARGET_GROUP_ARN}"
  aws elbv2 register-targets --region ${AWS_REGION} --target-group-arn ${TARGET_GROUP_ARN} --targets Id=${INSTANCE_ID},Port=${PORT}
done

echo "Target group registration complete!"
EOF

chmod +x /tmp/register_target_groups.sh

# Add a cron job to run the registration script every 5 minutes
# This ensures targets get registered even if ingress is installed after nodes join
(crontab -l 2>/dev/null || echo "") | grep -v "register_target_groups" | { cat; echo "*/5 * * * * /tmp/register_target_groups.sh >/tmp/register_target_groups.log 2>&1"; } | crontab -

# Run once immediately in the background
nohup /tmp/register_target_groups.sh >/tmp/register_target_groups.log 2>&1 &