#!/bin/bash
# This script helps access the Kubernetes Dashboard and other web UIs
# It can also automate port forwarding for these services

set -e

# Store PIDs for the port forwarding processes
DASHBOARD_PID_FILE="/tmp/k8s_dashboard_proxy.pid"
GRAFANA_PID_FILE="/tmp/k8s_grafana_proxy.pid"
PROMETHEUS_PID_FILE="/tmp/k8s_prometheus_proxy.pid"

# Handle command line arguments
if [ "$1" == "start" ] || [ "$1" == "autostart" ]; then
  AUTO_START=true
elif [ "$1" == "stop" ]; then
  STOP_PORTS=true
elif [ "$1" == "status" ]; then
  SHOW_STATUS=true
fi

# Get AWS region from Terraform
if [ -d "../terraform" ]; then
  TERRAFORM_DIR="../terraform"
elif [ -d "terraform" ]; then
  TERRAFORM_DIR="terraform"
else
  echo "Cannot find terraform directory"
  exit 1
fi

# Function to check if port is already in use
check_port() {
  local port=$1
  if lsof -i :$port >/dev/null 2>&1; then
    echo "Port $port is already in use. Please close the application using this port."
    return 1
  fi
  return 0
}

# Function to ensure the monitoring namespace exists
check_monitoring_namespace() {
  if ! kubectl get namespace monitoring >/dev/null 2>&1; then
    echo "Monitoring namespace not found. Have you installed monitoring with 'make monitoring-all'?"
    return 1
  fi
  return 0
}

# Function to ensure the kubernetes-dashboard namespace exists
check_dashboard_namespace() {
  if ! kubectl get namespace kubernetes-dashboard >/dev/null 2>&1; then
    echo "Kubernetes Dashboard namespace not found. Have you installed the dashboard with 'make monitoring-all'?"
    return 1
  fi
  return 0
}

# Function to stop existing port forwards
stop_existing_forwards() {
  echo "Checking for existing port forwards..."
  
  # Stop Kubernetes Dashboard proxy if running
  if [ -f $DASHBOARD_PID_FILE ]; then
    PID=$(cat $DASHBOARD_PID_FILE)
    if ps -p $PID > /dev/null 2>&1; then
      echo "Stopping existing Kubernetes Dashboard proxy (PID: $PID)"
      kill $PID 2>/dev/null || true
    fi
    rm $DASHBOARD_PID_FILE
  fi
  
  # Stop Grafana port forward if running
  if [ -f $GRAFANA_PID_FILE ]; then
    PID=$(cat $GRAFANA_PID_FILE)
    if ps -p $PID > /dev/null 2>&1; then
      echo "Stopping existing Grafana port forward (PID: $PID)"
      kill $PID 2>/dev/null || true
    fi
    rm $GRAFANA_PID_FILE
  fi
  
  # Stop Prometheus port forward if running
  if [ -f $PROMETHEUS_PID_FILE ]; then
    PID=$(cat $PROMETHEUS_PID_FILE)
    if ps -p $PID > /dev/null 2>&1; then
      echo "Stopping existing Prometheus port forward (PID: $PID)"
      kill $PID 2>/dev/null || true
    fi
    rm $PROMETHEUS_PID_FILE
  fi
  
  # Give processes time to terminate
  sleep 1
}

# Start Kubernetes Dashboard proxy
start_dashboard_proxy() {
  if check_dashboard_namespace && check_port 8001; then
    echo "Starting Kubernetes Dashboard proxy..."
    kubectl proxy --port=8001 &
    DASHBOARD_PID=$!
    echo $DASHBOARD_PID > $DASHBOARD_PID_FILE
    echo "Kubernetes Dashboard proxy started with PID: $DASHBOARD_PID"
    
    # Wait a bit to ensure the process is running
    sleep 1
    if ! ps -p $DASHBOARD_PID > /dev/null; then
      echo "Failed to start Kubernetes Dashboard proxy."
      return 1
    fi
  else
    echo "Skipping Kubernetes Dashboard proxy..."
    return 1
  fi
  return 0
}

# Start Grafana port forward
start_grafana_port_forward() {
  if check_monitoring_namespace && check_port 3000; then
    echo "Starting Grafana port forward..."
    kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80 &
    GRAFANA_PID=$!
    echo $GRAFANA_PID > $GRAFANA_PID_FILE
    echo "Grafana port forward started with PID: $GRAFANA_PID"
    
    # Wait a bit to ensure the process is running
    sleep 1
    if ! ps -p $GRAFANA_PID > /dev/null; then
      echo "Failed to start Grafana port forward."
      return 1
    fi
  else
    echo "Skipping Grafana port forward..."
    return 1
  fi
  return 0
}

# Start Prometheus port forward
start_prometheus_port_forward() {
  if check_monitoring_namespace && check_port 9090; then
    echo "Starting Prometheus port forward..."
    kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 &
    PROMETHEUS_PID=$!
    echo $PROMETHEUS_PID > $PROMETHEUS_PID_FILE
    echo "Prometheus port forward started with PID: $PROMETHEUS_PID"
    
    # Wait a bit to ensure the process is running
    sleep 1
    if ! ps -p $PROMETHEUS_PID > /dev/null; then
      echo "Failed to start Prometheus port forward."
      return 1
    fi
  else
    echo "Skipping Prometheus port forward..."
    return 1
  fi
  return 0
}

# Function to show the status of running ports
show_status() {
  echo "--------------------------------------------------------"
  echo "Port forwarding status:"
  
  if [ -f $DASHBOARD_PID_FILE ] && ps -p $(cat $DASHBOARD_PID_FILE) > /dev/null 2>&1; then
    echo "✅ Kubernetes Dashboard: http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
  else
    echo "❌ Kubernetes Dashboard: Not running"
  fi
  
  if [ -f $GRAFANA_PID_FILE ] && ps -p $(cat $GRAFANA_PID_FILE) > /dev/null 2>&1; then
    echo "✅ Grafana: http://localhost:3000 (admin/admin)"
  else
    echo "❌ Grafana: Not running"
  fi
  
  if [ -f $PROMETHEUS_PID_FILE ] && ps -p $(cat $PROMETHEUS_PID_FILE) > /dev/null 2>&1; then
    echo "✅ Prometheus: http://localhost:9090"
  else
    echo "❌ Prometheus: Not running"
  fi
  echo "--------------------------------------------------------"
}

# If we're just checking status
if [ "$SHOW_STATUS" == "true" ]; then
  show_status
  exit 0
fi

# If we're stopping port forwards
if [ "$STOP_PORTS" == "true" ]; then
  echo "Stopping all port forwards..."
  stop_existing_forwards
  echo "All port forwards stopped."
  exit 0
fi

# Get the dashboard token
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
    --filters "Name=tag:Role,Values=control-plane" "Name=instance-state-name,Values:running" \
    --query "Reservations[*].Instances[*].InstanceId" --output text)
fi
echo "Found instance IDs: $INSTANCE_IDS"

# Try local dashboard token first
if [ -f "dashboard-token.txt" ]; then
  echo "Found local dashboard token file."
  DASHBOARD_TOKEN=$(cat dashboard-token.txt)
  TOKEN_FOUND=true
else
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
      # Save the token locally for future use
      echo "$DASHBOARD_TOKEN" > dashboard-token.txt
      echo "Token saved to dashboard-token.txt"
      break
    else
      echo "Dashboard token not found on $CONTROL_PLANE_IP"
      
      # If Kubernetes is running but token file doesn't exist yet, create it
      if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -i ~/.ssh/id_rsa_aws ubuntu@$CONTROL_PLANE_IP "sudo [ -d /etc/kubernetes ]" >/dev/null 2>&1; then
        echo "Kubernetes is running on $CONTROL_PLANE_IP. Creating dashboard token..."
        
        # Check if dashboard namespace exists
        DASHBOARD_EXISTS=$(ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa_aws ubuntu@$CONTROL_PLANE_IP "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get ns kubernetes-dashboard --no-headers 2>/dev/null || echo ''")
        
        if [ -z "$DASHBOARD_EXISTS" ]; then
          echo "Dashboard not installed yet. Please run 'make monitoring-all' first"
          continue
        fi
        
        # Create token and save it
        ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa_aws ubuntu@$CONTROL_PLANE_IP "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kubernetes-dashboard create token admin-user > /tmp/dashboard-admin-token.txt 2>/dev/null"
        DASHBOARD_TOKEN=$(ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa_aws ubuntu@$CONTROL_PLANE_IP "sudo cat /tmp/dashboard-admin-token.txt 2>/dev/null")
        
        if [ ! -z "$DASHBOARD_TOKEN" ]; then
          TOKEN_FOUND=true
          # Save the token locally for future use
          echo "$DASHBOARD_TOKEN" > dashboard-token.txt
          echo "Token saved to dashboard-token.txt"
          break
        fi
      fi
    fi
  done
fi

# If token not found and we can create one locally
if [ "$TOKEN_FOUND" = false ]; then
  if kubectl get namespace kubernetes-dashboard >/dev/null 2>&1; then
    echo "Creating dashboard token locally..."
    DASHBOARD_TOKEN=$(kubectl -n kubernetes-dashboard create token admin-user 2>/dev/null)
    if [ $? -eq 0 ]; then
      echo "$DASHBOARD_TOKEN" > dashboard-token.txt
      echo "Token saved to dashboard-token.txt"
      TOKEN_FOUND=true
    fi
  fi
fi

if [ "$TOKEN_FOUND" = false ]; then
  echo "Error: Could not get dashboard token from any control plane node."
  echo "The Kubernetes Dashboard might not be installed yet."
  echo "Please run 'make monitoring-all' to install it"
  exit 1
fi

# If we're supposed to auto-start port forwards
if [ "$AUTO_START" == "true" ]; then
  # Stop any existing port forwards first
  stop_existing_forwards
  
  # Start all port forwards
  echo "Starting all monitoring port forwards..."
  start_dashboard_proxy
  start_grafana_port_forward
  start_prometheus_port_forward
  
  # Show status of port forwards
  show_status
  
  echo "Port forwarding is now running in the background!"
  echo "To stop all port forwards: ./scripts/access_dashboard.sh stop"
  echo "To check status: ./scripts/access_dashboard.sh status"
  echo
fi

# Always print access information
echo "=== Kubernetes Dashboard ==="
if [ -f $DASHBOARD_PID_FILE ] && ps -p $(cat $DASHBOARD_PID_FILE) > /dev/null 2>&1; then
  echo "Dashboard proxy is already running."
  echo "Access at: http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
else
  echo "To access the dashboard, run the following command in a separate terminal:"
  echo "kubectl proxy"
  echo 
  echo "Then open the following URL in your browser:"
  echo "http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
fi
echo
echo "Use the following token to log in:"
echo "$DASHBOARD_TOKEN"
echo

echo "=== Grafana (Monitoring) ==="
if [ -f $GRAFANA_PID_FILE ] && ps -p $(cat $GRAFANA_PID_FILE) > /dev/null 2>&1; then
  echo "Grafana port forward is already running."
  echo "Access at: http://localhost:3000"
else
  echo "To access Grafana, run the following command in a separate terminal:"
  echo "kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
  echo
  echo "Then open the following URL in your browser:"
  echo "http://localhost:3000"
fi
echo
echo "Username: admin"
echo "Password: admin"
echo

echo "=== Prometheus ==="
if [ -f $PROMETHEUS_PID_FILE ] && ps -p $(cat $PROMETHEUS_PID_FILE) > /dev/null 2>&1; then
  echo "Prometheus port forward is already running."
  echo "Access at: http://localhost:9090"
else
  echo "To access Prometheus, run the following command in a separate terminal:"
  echo "kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090"
  echo
  echo "Then open the following URL in your browser:"
  echo "http://localhost:9090"
fi
echo

echo "To automatically start all port forwards: ./scripts/access_dashboard.sh start"
echo "To stop all port forwards: ./scripts/access_dashboard.sh stop"
echo "To check status: ./scripts/access_dashboard.sh status"