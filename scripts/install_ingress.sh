#!/bin/bash
set -e

# Install NGINX Ingress Controller
echo "Installing NGINX Ingress Controller..."

# Check if Helm is installed
if ! command -v helm &> /dev/null; then
  echo "Helm not found, installing..."
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  echo "Helm is already installed"
fi

# Add the ingress-nginx repository
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Install NGINX Ingress Controller
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer

# Wait for Load Balancer to get external IP
echo "Waiting for Load Balancer to be ready..."
for i in {1..30}; do
  EXTERNAL_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  if [[ -n "$EXTERNAL_IP" && "$EXTERNAL_IP" != "null" ]]; then
    break
  fi
  echo "Waiting for external IP... ($i/30)"
  sleep 10
done

if [[ -z "$EXTERNAL_IP" || "$EXTERNAL_IP" == "null" ]]; then
  echo "Failed to get external IP for the Ingress controller"
  echo "Check the service status with: kubectl get svc -n ingress-nginx"
  exit 1
fi

echo
echo "NGINX Ingress Controller has been installed!"
echo "Load Balancer External IP/Hostname: $EXTERNAL_IP"
echo
echo "Point your domain's DNS records to this address to expose your services."
echo "Next, install cert-manager to handle SSL certificates with: ./scripts/install_cert_manager.sh"
echo 
echo "You will need to create Ingress resources for your services to expose them through your domain."