#!/bin/bash
set -e

# This script registers EC2 instances with AWS Load Balancer target groups
# It is meant to be run after the load balancer service has been created

# Get the AWS region from the instance metadata
AWS_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

# Find target groups containing "ingress" in the name
echo "Looking for ingress target groups in region ${AWS_REGION}..."
TARGET_GROUPS=$(aws elbv2 describe-target-groups --region ${AWS_REGION} --query "TargetGroups[?contains(TargetGroupName, 'ingress')].TargetGroupArn" --output text)

if [ -z "$TARGET_GROUPS" ]; then
  echo "No ingress target groups found."
  exit 0
fi

# For each target group, find its target port from the health check port and register the instance
for TARGET_GROUP_ARN in $TARGET_GROUPS; do
  echo "Processing target group: ${TARGET_GROUP_ARN}"
  
  # Get the health check port for this target group
  PORT=$(aws elbv2 describe-target-groups --region ${AWS_REGION} --target-group-arns ${TARGET_GROUP_ARN} --query "TargetGroups[0].Port" --output text)
  
  echo "Registering instance ${INSTANCE_ID} on port ${PORT} with target group ${TARGET_GROUP_ARN}"
  aws elbv2 register-targets --region ${AWS_REGION} --target-group-arn ${TARGET_GROUP_ARN} --targets Id=${INSTANCE_ID},Port=${PORT}
done

echo "Target group registration complete!"