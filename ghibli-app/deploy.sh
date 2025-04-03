#!/bin/bash
set -e

# Configuration
DOCKER_REGISTRY="docker.io/hpanchas"
IMAGE_NAME="ghibli-app"
IMAGE_TAG=$(date +%Y%m%d-%H%M%S)

# Build the Docker image for amd64 platform
echo "Building Docker image for amd64 platform..."
docker build --platform=linux/amd64 -t $IMAGE_NAME:$IMAGE_TAG .
docker tag $IMAGE_NAME:$IMAGE_TAG $DOCKER_REGISTRY/$IMAGE_NAME:$IMAGE_TAG
docker tag $IMAGE_NAME:$IMAGE_TAG $DOCKER_REGISTRY/$IMAGE_NAME:latest

# Push the Docker image
echo "Pushing Docker image to registry..."
docker push $DOCKER_REGISTRY/$IMAGE_NAME:$IMAGE_TAG
docker push $DOCKER_REGISTRY/$IMAGE_NAME:latest

# Update Kubernetes deployment files
echo "Updating Kubernetes deployment files..."
sed -i.bak "s|\${DOCKER_REGISTRY}|$DOCKER_REGISTRY|g" k8s/deployment.yaml

# Create service account if it doesn't exist
kubectl create serviceaccount ghibli-app-sa --dry-run=client -o yaml | kubectl apply -f -

# Apply Kubernetes resources
echo "Applying Kubernetes resources..."
kubectl apply -f k8s/deployment.yaml

# Wait for deployment to be ready
echo "Waiting for deployment to be ready..."
kubectl rollout status deployment/ghibli-app

# Restore original file
mv k8s/deployment.yaml.bak k8s/deployment.yaml

# Get the Load Balancer address
echo "Getting the Load Balancer information..."
sleep 10  # Brief pause to allow LB resource to be created

LB_HOSTNAME=$(kubectl get svc ghibli-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [ -z "$LB_HOSTNAME" ]; then
    echo "Load Balancer is provisioning. You can check its status with:"
    echo "kubectl get svc ghibli-app"
    echo "You can get the address later with: kubectl get svc ghibli-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
else
    echo "Ghibli app will be accessible at: http://$LB_HOSTNAME and https://$LB_HOSTNAME"
    echo "When the Load Balancer is ready, update your DNS records to point ghibli.doandlearn.app to $LB_HOSTNAME"
fi

echo "Deployment complete!"
