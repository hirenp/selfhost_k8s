#!/bin/bash
set -e

# Directory of the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"

# Get AWS region
AWS_REGION=$(terraform -chdir="$TERRAFORM_DIR" output -raw aws_region)
CLUSTER_NAME=$(terraform -chdir="$TERRAFORM_DIR" output -raw cluster_name)
ROLE_ARN=$(terraform -chdir="$TERRAFORM_DIR" output -raw aws_load_balancer_controller_role_arn)
BACKEND_SG_ID=$(terraform -chdir="$TERRAFORM_DIR" output -raw lb_controller_backend_sg_id 2>/dev/null || echo "")

echo "Installing AWS Load Balancer Controller in cluster $CLUSTER_NAME in region $AWS_REGION"

# Create namespace if it doesn't exist
kubectl create namespace kube-system --dry-run=client -o yaml | kubectl apply -f -

# Create ServiceAccount
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: ${ROLE_ARN}
EOF

# Install cert-manager (required for webhooks)
echo "Installing cert-manager..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml

# Wait for cert-manager to be ready
echo "Waiting for cert-manager pods to be ready..."
kubectl wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=cert-manager \
  --timeout=120s

# Add the AWS Load Balancer Controller Helm repository
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Install the AWS Load Balancer Controller
echo "Installing AWS Load Balancer Controller..."

# Construct the Helm values
HELM_VALUES="clusterName=${CLUSTER_NAME},serviceAccount.create=false,serviceAccount.name=aws-load-balancer-controller,region=${AWS_REGION}"

# Add VPC ID to the Helm values
VPC_ID=$(terraform -chdir="$TERRAFORM_DIR" output -raw vpc_id 2>/dev/null || echo "")
if [ -n "$VPC_ID" ]; then
  HELM_VALUES="${HELM_VALUES},vpcId=${VPC_ID}"
fi

# Add backend security group ID to the Helm values if available
if [ -n "$BACKEND_SG_ID" ]; then
  echo "Using backend security group: ${BACKEND_SG_ID}"
  HELM_VALUES="${HELM_VALUES},backendSecurityGroup=${BACKEND_SG_ID}"
fi

# Install the controller with the constructed values
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set "${HELM_VALUES}"

# Display configuration message
echo "AWS Load Balancer Controller configured with: ${HELM_VALUES}"

# Wait for the controller to be ready
echo "Waiting for AWS Load Balancer Controller to be ready..."
kubectl wait -n kube-system \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=aws-load-balancer-controller \
  --timeout=300s || echo "Timeout waiting for AWS Load Balancer Controller pods"

# Verify the installation
echo "Verifying AWS Load Balancer Controller installation..."
kubectl get deployment -n kube-system aws-load-balancer-controller

# Add an annotation to the k8s security group to allow it to be used for target registration
BACKEND_SG_ID=$(terraform -chdir="$TERRAFORM_DIR" output -raw lb_controller_backend_sg_id 2>/dev/null || echo "")
if [ -n "$BACKEND_SG_ID" ]; then
  echo "Configuring security group for target registration: ${BACKEND_SG_ID}"
  aws ec2 create-tags \
    --resources ${BACKEND_SG_ID} \
    --tags "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned" \
    --region ${AWS_REGION} || echo "Failed to tag security group, may need to be done manually"
fi

echo "AWS Load Balancer Controller has been installed successfully!"
echo ""
echo "You can now use LoadBalancer type services or create Ingress resources with the following annotations:"
echo ""
echo "For LoadBalancer service:"
echo "apiVersion: v1"
echo "kind: Service"
echo "metadata:"
echo "  name: your-service"
echo "  annotations:"
echo "    service.beta.kubernetes.io/aws-load-balancer-type: \"nlb\""
echo "spec:"
echo "  type: LoadBalancer"
echo "  ports:"
echo "  - port: 80"
echo "    targetPort: 8080"
echo "  selector:"
echo "    app: your-app"
echo ""
echo "For Ingress (ALB):"
echo "apiVersion: networking.k8s.io/v1"
echo "kind: Ingress"
echo "metadata:"
echo "  name: your-ingress"
echo "  annotations:"
echo "    kubernetes.io/ingress.class: alb"
echo "    alb.ingress.kubernetes.io/scheme: internet-facing"
echo "    alb.ingress.kubernetes.io/target-type: ip"
echo "spec:"
echo "  rules:"
echo "  - host: example.com"
echo "    http:"
echo "      paths:"
echo "      - path: /"
echo "        pathType: Prefix"
echo "        backend:"
echo "          service:"
echo "            name: your-service"
echo "            port:"
echo "              number: 80"