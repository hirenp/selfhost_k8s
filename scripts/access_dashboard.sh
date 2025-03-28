#!/bin/bash
set -e

# This script helps access the Kubernetes Dashboard and other web UIs

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

# If no instances found through ASG, try direct EC2 query with tag filter
if [ -z "$INSTANCE_IDS" ]; then
  echo "No instances found in ASG, trying direct EC2 query..."
  INSTANCE_IDS=$(aws ec2 describe-instances --region $AWS_REGION \
    --filters "Name=tag:Role,Values=control-plane" "Name=instance-state-name,Values=running" \
    --query "Reservations[*].Instances[*].InstanceId" --output text)
fi
echo "Found instance IDs: $INSTANCE_IDS"

# Find a control plane node that has the dashboard token
TOKEN_FOUND=false

for INSTANCE_ID in $INSTANCE_IDS; do
  # Get public IP
  CONTROL_PLANE_IP=$(aws ec2 describe-instances --region $AWS_REGION --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  echo "Checking control plane node at IP: $CONTROL_PLANE_IP"
  
  # Try to get dashboard token
  echo "Trying to connect with SSH key: ~/.ssh/id_rsa_aws"
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -i ~/.ssh/id_rsa_aws ubuntu@$CONTROL_PLANE_IP "sudo ls /tmp/dashboard-admin-token.txt" >/dev/null 2>&1; then
    echo "Found dashboard token on node $CONTROL_PLANE_IP"
    DASHBOARD_TOKEN=$(ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa_aws ubuntu@$CONTROL_PLANE_IP "sudo cat /tmp/dashboard-admin-token.txt")
    TOKEN_FOUND=true
    break
  else
    echo "Dashboard token not found on $CONTROL_PLANE_IP"
    
    # If Kubernetes is running but token file doesn't exist yet, create it
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -i ~/.ssh/id_rsa_aws ubuntu@$CONTROL_PLANE_IP "sudo [ -d /etc/kubernetes ]" >/dev/null 2>&1; then
      echo "Kubernetes is running on $CONTROL_PLANE_IP. Creating dashboard token..."
      
      # Check if dashboard namespace exists
      DASHBOARD_EXISTS=$(ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa_aws ubuntu@$CONTROL_PLANE_IP "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get ns kubernetes-dashboard --no-headers 2>/dev/null || echo ''")
      
      if [ -z "$DASHBOARD_EXISTS" ]; then
        echo "Dashboard not installed yet. Please run ./scripts/install_dashboard.sh first"
        continue
      fi
      
      # Create token and save it
      ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa_aws ubuntu@$CONTROL_PLANE_IP "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kubernetes-dashboard create token admin-user > /tmp/dashboard-admin-token.txt 2>/dev/null"
      DASHBOARD_TOKEN=$(ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa_aws ubuntu@$CONTROL_PLANE_IP "sudo cat /tmp/dashboard-admin-token.txt 2>/dev/null")
      
      if [ ! -z "$DASHBOARD_TOKEN" ]; then
        TOKEN_FOUND=true
        break
      fi
    fi
  fi
done

if [ "$TOKEN_FOUND" = false ]; then
  echo "Error: Could not get dashboard token from any control plane node."
  echo "The Kubernetes Dashboard might not be installed yet."
  echo "Please run the following command to install it:"
  echo "./scripts/install_dashboard.sh"
  exit 1
fi

echo "=== Kubernetes Dashboard ==="
echo "To access the dashboard, run the following command in a separate terminal:"
echo "kubectl proxy"
echo 
echo "Then open the following URL in your browser:"
echo "http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
echo
echo "Use the following token to log in:"
echo
echo "$DASHBOARD_TOKEN"
echo
echo "=== Grafana (Monitoring) ==="
echo "To access Grafana, run the following command in a separate terminal:"
echo "kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
echo
echo "Then open the following URL in your browser:"
echo "http://localhost:3000"
echo
echo "Username: admin"
echo "Password: prom-operator"
echo
echo "=== Prometheus ==="
echo "To access Prometheus, run the following command in a separate terminal:"
echo "kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090"
echo
echo "Then open the following URL in your browser:"
echo "http://localhost:9090"