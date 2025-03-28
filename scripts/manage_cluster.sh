#!/bin/bash
set -e

# Get AWS region from Terraform
AWS_REGION=$(terraform -chdir=../terraform output -raw aws_region 2>/dev/null || echo "us-west-1")

# Get ASG names from Terraform or use defaults
CONTROL_PLANE_ASG=$(terraform -chdir=../terraform output -raw control_plane_asg_name 2>/dev/null || echo "k8s-control-plane-asg")
WORKER_ASG=$(terraform -chdir=../terraform output -raw worker_asg_name 2>/dev/null || echo "k8s-worker-asg")

# Get the action argument
ACTION=$1

# Function to check ASG status
check_asg_status() {
  local asg_name=$1
  local status=$(aws autoscaling describe-auto-scaling-groups --region $AWS_REGION --auto-scaling-group-names "$asg_name" --query 'AutoScalingGroups[0].Instances[*].LifecycleState' --output text)
  echo "Status of $asg_name: $status"
}

case "$ACTION" in
  sleep)
    echo "📉 Scaling down clusters for sleep mode..."
    
    echo "Setting control plane ASG ($CONTROL_PLANE_ASG) to 0 instances"
    aws autoscaling update-auto-scaling-group --region $AWS_REGION --auto-scaling-group-name $CONTROL_PLANE_ASG --min-size 0 --desired-capacity 0
    
    echo "Setting worker ASG ($WORKER_ASG) to 0 instances"
    aws autoscaling update-auto-scaling-group --region $AWS_REGION --auto-scaling-group-name $WORKER_ASG --min-size 0 --desired-capacity 0
    
    echo "Waiting for instances to terminate..."
    sleep 10
    check_asg_status $CONTROL_PLANE_ASG
    check_asg_status $WORKER_ASG
    
    echo "💤 Clusters scaled down. Good night!"
    ;;
    
  wake)
    echo "🌅 Waking up clusters..."
    
    echo "Setting control plane ASG ($CONTROL_PLANE_ASG) to 2 instances"
    aws autoscaling update-auto-scaling-group --region $AWS_REGION --auto-scaling-group-name $CONTROL_PLANE_ASG --min-size 2 --desired-capacity 2
    
    echo "Setting worker ASG ($WORKER_ASG) to 3 instances"
    aws autoscaling update-auto-scaling-group --region $AWS_REGION --auto-scaling-group-name $WORKER_ASG --min-size 3 --desired-capacity 3
    
    echo "Waiting for instances to start..."
    sleep 10
    check_asg_status $CONTROL_PLANE_ASG
    check_asg_status $WORKER_ASG
    
    echo "🚀 Clusters scaling up. This may take a few minutes."
    echo "The cluster will be fully operational in about 5-10 minutes."
    echo "Run ./scripts/setup_kubeconfig.sh once the instances are running."
    ;;
    
  status)
    echo "📊 Checking cluster status..."
    
    echo "Control plane ASG ($CONTROL_PLANE_ASG):"
    aws autoscaling describe-auto-scaling-groups --region $AWS_REGION --auto-scaling-group-names "$CONTROL_PLANE_ASG" \
      --query 'AutoScalingGroups[0].[MinSize,DesiredCapacity,MaxSize]' --output text | \
      awk '{print "  Min size: " $1 "\n  Desired capacity: " $2 "\n  Max size: " $3}'
    
    echo "Worker ASG ($WORKER_ASG):"
    aws autoscaling describe-auto-scaling-groups --region $AWS_REGION --auto-scaling-group-names "$WORKER_ASG" \
      --query 'AutoScalingGroups[0].[MinSize,DesiredCapacity,MaxSize]' --output text | \
      awk '{print "  Min size: " $1 "\n  Desired capacity: " $2 "\n  Max size: " $3}'
    
    echo -e "\nInstance Status:"
    check_asg_status $CONTROL_PLANE_ASG
    check_asg_status $WORKER_ASG
    
    echo -e "\nInstance Details:"
    echo "Control Plane Nodes:"
    echo "Checking instance details and hostnames..."
    
    # Display table header for control plane nodes
    printf "%-20s %-15s %-15s %-15s %-20s\n" "INSTANCE ID" "PRIVATE IP" "PUBLIC IP" "STATE" "HOSTNAME"
    
    # Get all control plane instances using ASG tag
    CP_INSTANCES=$(aws ec2 describe-instances --region $AWS_REGION \
      --filters "Name=tag:aws:autoscaling:groupName,Values=$CONTROL_PLANE_ASG" "Name=instance-state-name,Values=running" \
      --output json | jq -r '.Reservations[].Instances[] | [.InstanceId, .PrivateIpAddress, .PublicIpAddress, .State.Name] | @tsv')
    
    # Check if any instances were found
    if [ -z "$CP_INSTANCES" ]; then
      echo "No control plane instances running"
    else
      # Loop through each instance
      while IFS=$'\t' read -r INSTANCE_ID PRIVATE_IP PUBLIC_IP STATE; do
        # Try to get hostname via SSH
        if [ ! -z "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "null" ]; then
          HOSTNAME=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes -i ~/.ssh/id_rsa_aws ubuntu@$PUBLIC_IP "hostname" 2>/dev/null || echo "N/A")
        else
          HOSTNAME="N/A (no public IP)"
        fi
        
        # Handle missing values
        [ -z "$PRIVATE_IP" ] && PRIVATE_IP="N/A"
        [ "$PUBLIC_IP" = "null" ] && PUBLIC_IP="N/A"
        [ -z "$STATE" ] && STATE="unknown"
        
        printf "%-20s %-15s %-15s %-15s %-20s\n" "$INSTANCE_ID" "$PRIVATE_IP" "$PUBLIC_IP" "$STATE" "$HOSTNAME"
      done <<< "$CP_INSTANCES"
    fi
    
    echo -e "\nWorker Nodes:"
    
    # Display table header for worker nodes
    printf "%-20s %-15s %-15s %-15s %-20s\n" "INSTANCE ID" "PRIVATE IP" "PUBLIC IP" "STATE" "HOSTNAME"
    
    # Get all worker instances using ASG tag
    WORKER_INSTANCES=$(aws ec2 describe-instances --region $AWS_REGION \
      --filters "Name=tag:aws:autoscaling:groupName,Values=$WORKER_ASG" "Name=instance-state-name,Values=running" \
      --output json | jq -r '.Reservations[].Instances[] | [.InstanceId, .PrivateIpAddress, .PublicIpAddress, .State.Name] | @tsv')
    
    # Check if any instances were found
    if [ -z "$WORKER_INSTANCES" ]; then
      echo "No worker instances running"
    else
      # Loop through each instance
      while IFS=$'\t' read -r INSTANCE_ID PRIVATE_IP PUBLIC_IP STATE; do
        # Try to get hostname via SSH
        if [ ! -z "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "null" ]; then
          HOSTNAME=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes -i ~/.ssh/id_rsa_aws ubuntu@$PUBLIC_IP "hostname" 2>/dev/null || echo "N/A")
        else
          HOSTNAME="N/A (no public IP)"
        fi
        
        # Handle missing values
        [ -z "$PRIVATE_IP" ] && PRIVATE_IP="N/A"
        [ "$PUBLIC_IP" = "null" ] && PUBLIC_IP="N/A"
        [ -z "$STATE" ] && STATE="unknown"
        
        printf "%-20s %-15s %-15s %-15s %-20s\n" "$INSTANCE_ID" "$PRIVATE_IP" "$PUBLIC_IP" "$STATE" "$HOSTNAME"
      done <<< "$WORKER_INSTANCES"
    fi
      
    # Check load balancer
    echo -e "\nLoad Balancer:"
    LB_DNS=$(terraform -chdir=../terraform output -raw k8s_api_lb_dns 2>/dev/null || echo "Not found")
    
    if [ "$LB_DNS" = "Not found" ]; then
      echo "API Load Balancer DNS: Not found - cluster may not be deployed yet"
      # Don't exit with error
      echo "ℹ️ Load balancer DNS not found - run 'terraform apply' first"
    else
      echo "API Load Balancer DNS: $LB_DNS"
      
      # Check if we can connect to the k8s API
      echo -e "\nKubernetes API Accessibility:"
      if command -v nc &> /dev/null; then
        nc -z -w 5 $LB_DNS 6443 &>/dev/null
        if [ $? -eq 0 ]; then
          echo "✅ Kubernetes API is accessible at $LB_DNS:6443"
          
          # Try to get node status if kubectl is available and configured
          if command -v kubectl &> /dev/null && [ -f "$HOME/.kube/config" ]; then
            echo -e "\nKubernetes Node Status:"
            kubectl get nodes -o wide 2>/dev/null || echo "⚠️ Could not get node status. Run './scripts/setup_kubeconfig.sh' first."
            
            echo -e "\nKubernetes System Pods Status:"
            kubectl get pods -n kube-system 2>/dev/null || echo "⚠️ Could not get pod status."
          else
            echo "⚠️ kubectl not found or not configured. Run './scripts/setup_kubeconfig.sh' to set up access."
          fi
        else
          echo "❌ Kubernetes API is NOT accessible at $LB_DNS:6443 (might still be initializing)"
        fi
      else
        echo "❓ Cannot check API accessibility (netcat not available)"
      fi
    fi
    ;;
    
  check-hostnames)
    echo "🔍 Checking for hostname conflicts..."
    
    # Get all instances from both ASGs
    CP_INSTANCES=$(aws ec2 describe-instances --region $AWS_REGION \
      --filters "Name=tag:aws:autoscaling:groupName,Values=$CONTROL_PLANE_ASG" "Name=instance-state-name,Values=running" \
      --output json | jq -r '.Reservations[].Instances[] | [.InstanceId, .PrivateIpAddress, .PublicIpAddress, "control-plane"] | @tsv')
      
    WORKER_INSTANCES=$(aws ec2 describe-instances --region $AWS_REGION \
      --filters "Name=tag:aws:autoscaling:groupName,Values=$WORKER_ASG" "Name=instance-state-name,Values=running" \
      --output json | jq -r '.Reservations[].Instances[] | [.InstanceId, .PrivateIpAddress, .PublicIpAddress, "worker"] | @tsv')
      
    # Combine the results
    ALL_INSTANCES="$CP_INSTANCES
$WORKER_INSTANCES"
    
    # Arrays to track hostnames and instances
    declare HOSTNAME_LIST=()
    declare INSTANCE_ID_LIST=()
    declare PUBLIC_IP_LIST=()
    declare PRIVATE_IP_LIST=()
    
    # If we have any instances, check their hostnames
    if [ ! -z "$ALL_INSTANCES" ]; then
      # Process each instance and build the arrays
      while IFS=$'\t' read -r INSTANCE_ID PRIVATE_IP PUBLIC_IP ROLE; do
        # Skip empty lines
        [ -z "$INSTANCE_ID" ] && continue
        
        # Handle null values
        [ "$PRIVATE_IP" = "null" ] && PRIVATE_IP="N/A"
        [ -z "$ROLE" ] && ROLE="unknown"
        
        if [ ! -z "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "null" ]; then
          echo "Checking hostname for instance $INSTANCE_ID ($ROLE) via public IP $PUBLIC_IP..."
          HOSTNAME=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes -i ~/.ssh/id_rsa_aws ubuntu@$PUBLIC_IP "hostname" 2>/dev/null || echo "N/A")
        else
          echo "⚠️ Instance $INSTANCE_ID ($ROLE) has no public IP, listing in inventory only"
          HOSTNAME="unknown (no public IP access)"
          PUBLIC_IP="N/A"
        fi
        
        # Always print instance info for inventory purposes
        printf "Instance: %-20s Private IP: %-15s Public IP: %-15s Role: %-10s Hostname: %s\n" \
          "$INSTANCE_ID" "$PRIVATE_IP" "$PUBLIC_IP" "$ROLE" "$HOSTNAME"
        
        # If we got a valid hostname, check for conflicts
        if [ "$HOSTNAME" != "N/A" ] && [ "$HOSTNAME" != "unknown (no public IP access)" ]; then
          # Check if this hostname is already in our list
          CONFLICT_FOUND=false
          CONFLICT_IDX=-1
          
          for i in "${!HOSTNAME_LIST[@]}"; do
            if [ "${HOSTNAME_LIST[$i]}" = "$HOSTNAME" ]; then
              CONFLICT_FOUND=true
              CONFLICT_IDX=$i
              break
            fi
          done
          
          if [ "$CONFLICT_FOUND" = "false" ]; then
            # First time seeing this hostname - add to arrays
            HOSTNAME_LIST+=("$HOSTNAME")
            INSTANCE_ID_LIST+=("$INSTANCE_ID")
            PUBLIC_IP_LIST+=("$PUBLIC_IP")
            PRIVATE_IP_LIST+=("$PRIVATE_IP")
          else
            # We found a conflict!
            echo "❌ CONFLICT: $INSTANCE_ID has the same hostname ($HOSTNAME) as ${INSTANCE_ID_LIST[$CONFLICT_IDX]}"
            echo "   To fix, SSH into the node and change the hostname:"
            if [ "$PUBLIC_IP" != "N/A" ]; then
              echo "   ssh -i ~/.ssh/id_rsa_aws ubuntu@$PUBLIC_IP"
            else
              echo "   Connect to instance $INSTANCE_ID (via AWS Session Manager or other method)"
            fi
            echo "   sudo hostnamectl set-hostname <new-unique-name>"
            echo "   sudo kubeadm reset -f"
            echo "   # Then get a new join command and rejoin with --node-name parameter"
          fi
        fi
      done <<< "$ALL_INSTANCES"
      
      # Print summary of all hostnames
      if [ ${#HOSTNAME_LIST[@]} -gt 0 ]; then
        echo -e "\nHostname inventory:"
        for i in "${!HOSTNAME_LIST[@]}"; do
          echo "Hostname: ${HOSTNAME_LIST[$i]} -> Instance: ${INSTANCE_ID_LIST[$i]} (Public IP: ${PUBLIC_IP_LIST[$i]}, Private IP: ${PRIVATE_IP_LIST[$i]})"
        done
      else
        echo -e "\nNo valid hostnames could be determined."
      fi
    else
      echo "No running instances found"
    fi
    
    echo -e "\nDone checking hostnames."
    ;;
    
  *)
    echo "❓ Usage: $0 {sleep|wake|status|check-hostnames}"
    echo
    echo "Commands:"
    echo "  sleep           - Scale down all instances (to save costs)"
    echo "  wake            - Scale up instances to normal levels"
    echo "  status          - Check current cluster status"
    echo "  check-hostnames - Check for hostname conflicts across instances"
    exit 1
    ;;
esac