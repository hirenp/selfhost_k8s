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