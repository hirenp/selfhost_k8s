#!/bin/bash
set -e

# Determine terraform directory
if [ -d "../terraform" ]; then
  TERRAFORM_DIR="../terraform"
elif [ -d "terraform" ]; then
  TERRAFORM_DIR="terraform"
else
  echo "Cannot find terraform directory"
  exit 1
fi

# Get AWS region from Terraform
AWS_REGION=$(terraform -chdir=$TERRAFORM_DIR output -raw aws_region 2>/dev/null || echo "us-west-1")
echo "Using AWS region: $AWS_REGION"

# Get the action from command line
ACTION=$1

# Function to install Kubernetes Dashboard
install_dashboard() {
  echo "Installing Kubernetes Dashboard..."
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml

  echo "Creating Admin Service Account for Dashboard..."
  cat <<EOF | kubectl apply -f -
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

  # Generate and save the token
  echo "Generating dashboard access token..."
  kubectl -n kubernetes-dashboard create token admin-user > dashboard-token.txt

  # Display token information
  TOKEN=$(cat dashboard-token.txt)
  echo
  echo "Dashboard installation complete!"
  echo "Token has been saved to dashboard-token.txt"
  echo
  echo "Run '$0 access' to get access instructions"
}

# Function to install Prometheus and Grafana
install_monitoring() {
  echo "Installing Helm if not already installed..."
  if ! command -v helm &> /dev/null; then
    echo "Helm not found, installing..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  else
    echo "Helm is already installed"
  fi

  # Add the Prometheus Helm repository
  echo "Adding Prometheus Helm repository..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update

  # Install kube-prometheus-stack (includes Prometheus, Grafana, and Alertmanager)
  echo "Installing Prometheus and Grafana..."
  helm install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --create-namespace \
    --set grafana.adminPassword=admin \
    --set prometheus.service.type=ClusterIP

  echo
  echo "Monitoring installation complete!"
  echo "Run '$0 access' to get access instructions"
}

# Function to access monitoring components
access_monitoring() {
  # Get the control plane ASG name
  CONTROL_PLANE_ASG=$(terraform -chdir=$TERRAFORM_DIR output -raw control_plane_asg_name 2>/dev/null || echo "k8s-control-plane-asg")
  echo "Control plane ASG: $CONTROL_PLANE_ASG"

  # Get the instance IDs from the ASG
  INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups --region $AWS_REGION --auto-scaling-group-names "$CONTROL_PLANE_ASG" --query 'AutoScalingGroups[0].Instances[*].InstanceId' --output text)

  # If no instances found through ASG, try direct EC2 query with tag filter
  if [ -z "$INSTANCE_IDS" ]; then
    echo "No instances found in ASG, trying direct EC2 query..."
    INSTANCE_IDS=$(aws ec2 describe-instances --region $AWS_REGION \
      --filters "Name:tag:Role,Values:control-plane" "Name:instance-state-name,Values:running" \
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
          echo "Dashboard not installed yet. Please run '$0 install-dashboard' first"
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

  # Check if Kubernetes Dashboard is installed
  DASHBOARD_INSTALLED=$(kubectl get ns kubernetes-dashboard --no-headers 2>/dev/null || echo "")
  
  # Check if Prometheus/Grafana is installed  
  MONITORING_INSTALLED=$(kubectl get ns monitoring --no-headers 2>/dev/null || echo "")

  echo "=================================================="
  echo "           MONITORING ACCESS INFORMATION          "
  echo "=================================================="
  
  if [ ! -z "$DASHBOARD_INSTALLED" ]; then
    echo "=== Kubernetes Dashboard ==="
    echo "To access the dashboard, run the following command in a separate terminal:"
    echo "kubectl proxy"
    echo 
    echo "Then open the following URL in your browser:"
    echo "http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
    echo
    
    if [ "$TOKEN_FOUND" = true ]; then
      echo "Use the following token to log in:"
      echo
      echo "$DASHBOARD_TOKEN"
    else
      echo "To generate a token to log in, run:"
      echo "kubectl -n kubernetes-dashboard create token admin-user"
    fi
    echo
  else
    echo "=== Kubernetes Dashboard ==="
    echo "Kubernetes Dashboard is not installed."
    echo "To install it, run: $0 install-dashboard"
    echo
  fi

  if [ ! -z "$MONITORING_INSTALLED" ]; then
    echo "=== Grafana (Monitoring) ==="
    echo "To access Grafana, run the following command in a separate terminal:"
    echo "kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
    echo
    echo "Then open the following URL in your browser:"
    echo "http://localhost:3000"
    echo
    echo "Username: admin"
    echo "Password: admin"
    echo
    
    echo "=== Prometheus ==="
    echo "To access Prometheus, run the following command in a separate terminal:"
    echo "kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090"
    echo
    echo "Then open the following URL in your browser:"
    echo "http://localhost:9090"
  else
    echo "=== Monitoring (Prometheus/Grafana) ==="
    echo "Monitoring is not installed."
    echo "To install it, run: $0 install-monitoring"
    echo
  fi

  echo "=================================================="
}

# Function to install everything at once
install_all() {
  install_dashboard
  echo
  install_monitoring
  echo
  access_monitoring
}

# Main script logic
case "$ACTION" in
  install-dashboard)
    install_dashboard
    ;;
  install-monitoring)
    install_monitoring
    ;;
  install-all)
    install_all
    ;;
  access)
    access_monitoring
    ;;
  *)
    echo "Usage: $0 {install-dashboard|install-monitoring|install-all|access}"
    echo
    echo "Commands:"
    echo "  install-dashboard   - Install the Kubernetes Dashboard"
    echo "  install-monitoring  - Install Prometheus and Grafana for monitoring"
    echo "  install-all         - Install both Dashboard and Monitoring"
    echo "  access              - Show access information for all monitoring tools"
    exit 1
    ;;
esac