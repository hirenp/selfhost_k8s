#!/bin/bash
set -e

# This script helps set up kubeconfig from the k8s cluster
# It should be run after terraform apply completes

# Get AWS region from Terraform
if [ -d "../terraform" ]; then
  TERRAFORM_DIR="../terraform"
elif [ -d "terraform" ]; then
  TERRAFORM_DIR="terraform"
else
  echo "Cannot find terraform directory"
  exit 1
fi

AWS_REGION=$(terraform -chdir=$TERRAFORM_DIR output -raw aws_region 2>/dev/null || echo "us-west-1")
echo "Using AWS region: $AWS_REGION"

# Get the control plane ASG name
CONTROL_PLANE_ASG=$(terraform -chdir=$TERRAFORM_DIR output -raw control_plane_asg_name 2>/dev/null || echo "k8s-control-plane-asg")
echo "Control plane ASG: $CONTROL_PLANE_ASG"

# Get the instance IDs from the ASG
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups --region $AWS_REGION --auto-scaling-group-names "$CONTROL_PLANE_ASG" --query 'AutoScalingGroups[0].Instances[*].InstanceId' --output text)
echo "Found instance IDs: $INSTANCE_IDS"

# Get the load balancer DNS
LB_DNS=$(terraform -chdir=$TERRAFORM_DIR output -raw k8s_api_lb_dns 2>/dev/null || echo "")
echo "Load balancer DNS: $LB_DNS"

# Check if any of the control plane nodes are ready and have admin.conf
KUBECONFIG_FOUND=false

for INSTANCE_ID in $INSTANCE_IDS; do
  # Get public IP
  CONTROL_PLANE_IP=$(aws ec2 describe-instances --region $AWS_REGION --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  echo "Checking control plane node at IP: $CONTROL_PLANE_IP"
  
  # Check if the node is reachable via SSH - use a short timeout
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -i ~/.ssh/id_rsa_aws ubuntu@$CONTROL_PLANE_IP "echo 'SSH connection successful'" >/dev/null 2>&1; then
    echo "SSH connection successful to $CONTROL_PLANE_IP"
    
    # Check if Kubernetes is initialized
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -i ~/.ssh/id_rsa_aws ubuntu@$CONTROL_PLANE_IP "sudo ls /etc/kubernetes/admin.conf" >/dev/null 2>&1; then
      echo "Found Kubernetes config on node $CONTROL_PLANE_IP"
      
      # Create local .kube directory if it doesn't exist
      mkdir -p ~/.kube
      
      # Copy the kubeconfig from the control plane node
      echo "Copying kubeconfig from $CONTROL_PLANE_IP"
      ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i ~/.ssh/id_rsa_aws ubuntu@$CONTROL_PLANE_IP "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/config
      
      # Also copy the CA certificate to ensure proper verification
      echo "Copying CA certificate from $CONTROL_PLANE_IP"
      ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i ~/.ssh/id_rsa_aws ubuntu@$CONTROL_PLANE_IP "sudo cat /etc/kubernetes/pki/ca.crt" > ~/.kube/k8s-ca.crt
      
      # Update the server address to use the load balancer DNS
      sed -i'' -e "s|server: https://.*:6443|server: https://$LB_DNS:6443|g" ~/.kube/config
      
      KUBECONFIG_FOUND=true
      break
    else
      echo "Kubernetes not yet initialized on $CONTROL_PLANE_IP"
    fi
  else
    echo "Could not connect to $CONTROL_PLANE_IP via SSH, trying next node..."
  fi
done

if [ "$KUBECONFIG_FOUND" = true ]; then
  echo "======================================================"
  echo "Kubeconfig has been set up at ~/.kube/config"
  echo "You can now use kubectl to interact with your Kubernetes cluster"
  echo ""
  echo "Testing connection to cluster..."
  kubectl cluster-info
  echo ""
  echo "Getting nodes..."
  kubectl get nodes
  
  # Check if any nodes have GPU features
  GPU_NODES=$(kubectl get nodes -l GPU=true -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  if [ ! -z "$GPU_NODES" ]; then
    echo "Detected GPU nodes: $GPU_NODES"
    echo "Installing NVIDIA Device Plugin for Kubernetes..."
    
    # Install NVIDIA Device Plugin
    kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml
    
    echo "Waiting for NVIDIA device plugin daemonset to be ready..."
    kubectl -n kube-system rollout status daemonset/nvidia-device-plugin-daemonset 2>/dev/null
    
    echo "Verifying GPU nodes..."
    kubectl get nodes -o=custom-columns=NAME:.metadata.name,GPU:.status.capacity.'nvidia\.com/gpu'
    
    echo "To test GPU availability, you can run a sample pod with:"
    echo "kubectl apply -f - <<EOF"
    echo "apiVersion: v1"
    echo "kind: Pod"
    echo "metadata:"
    echo "  name: gpu-test"
    echo "spec:"
    echo "  restartPolicy: Never"
    echo "  containers:"
    echo "    - name: cuda-container"
    echo "      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.6.0"
    echo "      resources:"
    echo "        limits:"
    echo "          nvidia.com/gpu: 1"
    echo "EOF"
  else
    echo "No GPU nodes detected. If you're expecting GPU nodes, they might not be labeled properly."
    echo "You can check node labels with: kubectl get nodes --show-labels"
  fi
  
  echo ""
  echo "Note: To set up kubectl on any control plane node, run the following commands:"
  echo "  mkdir -p \$HOME/.kube"
  echo "  sudo cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config"
  echo "  sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config"
  echo "This should be done automatically on new nodes, but may be needed after a reboot."
else
  echo "======================================================"
  echo "Error: Could not get kubeconfig from any control plane node."
  echo "The Kubernetes cluster might still be initializing."
  echo "Wait a few minutes and try again."
  exit 1
fi