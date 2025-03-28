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
    
    echo "Instances:"
    check_asg_status $CONTROL_PLANE_ASG
    check_asg_status $WORKER_ASG
    ;;
    
  *)
    echo "❓ Usage: $0 {sleep|wake|status}"
    echo
    echo "Commands:"
    echo "  sleep   - Scale down all instances (to save costs)"
    echo "  wake    - Scale up instances to normal levels"
    echo "  status  - Check current cluster status"
    exit 1
    ;;
esac