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

# Apply Kubernetes resources
echo "Applying Kubernetes resources..."
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/ingress.yaml

# Wait for deployment to be ready
echo "Waiting for deployment to be ready..."
kubectl rollout status deployment/ghibli-app

# Restore original file
mv k8s/deployment.yaml.bak k8s/deployment.yaml

echo "Deployment complete!"
echo "Application should be accessible at: https://ghibli.doandlearn.app"
