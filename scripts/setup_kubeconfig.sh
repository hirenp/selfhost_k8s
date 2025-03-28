#!/bin/bash
set -e

# This script helps set up kubeconfig from the k8s cluster
# It should be run after terraform apply completes

# Get the control plane ASG name
CONTROL_PLANE_ASG=$(terraform -chdir=../terraform output -raw control_plane_asg_name)

# Get the instance IDs from the ASG
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$CONTROL_PLANE_ASG" --query 'AutoScalingGroups[0].Instances[*].InstanceId' --output text)

# Get the first instance ID
FIRST_INSTANCE_ID=$(echo $INSTANCE_IDS | awk '{print $1}')

# Get the IP address of the first control plane node
CONTROL_PLANE_IP=$(aws ec2 describe-instances --instance-ids "$FIRST_INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

if [ -z "$CONTROL_PLANE_IP" ]; then
  echo "Error: Could not get control plane IP address."
  echo "Make sure terraform has been applied successfully."
  exit 1
fi

echo "Retrieving kubeconfig from control plane at $CONTROL_PLANE_IP"

# Create local .kube directory if it doesn't exist
mkdir -p ~/.kube

# Copy the kubeconfig from the control plane node
scp -o StrictHostKeyChecking=no ubuntu@$CONTROL_PLANE_IP:/etc/kubernetes/admin.conf ~/.kube/config

# Update the server address to use the load balancer DNS
LB_DNS=$(terraform -chdir=../terraform output -raw k8s_api_lb_dns)
sed -i'' -e "s|server: https://.*:6443|server: https://$LB_DNS:6443|g" ~/.kube/config

echo "Kubeconfig has been set up at ~/.kube/config"
echo "You can now use kubectl to interact with your Kubernetes cluster"

# Test the connection
kubectl cluster-info