#!/bin/bash
set -e

# Install cert-manager for SSL certificates
echo "Installing cert-manager..."

# Check if Helm is installed
if ! command -v helm &> /dev/null; then
  echo "Helm not found, installing..."
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  echo "Helm is already installed"
fi

# Add the Jetstack repo for cert-manager
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Install cert-manager
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true

# Wait for cert-manager to become ready
echo "Waiting for cert-manager pods to become ready..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/instance=cert-manager --namespace cert-manager --timeout=180s

echo
echo "cert-manager has been installed!"
echo
echo "To set up Let's Encrypt with Cloudflare DNS, you'll need to create a ClusterIssuer."
echo "First, create a Cloudflare API token with Zone:DNS:Edit permissions."
echo 
echo "Then create a secret for your Cloudflare API token:"
echo "kubectl create secret generic cloudflare-api-token -n cert-manager --from-literal=api-token=YOUR_CLOUDFLARE_API_TOKEN"
echo
echo "Now run: ./scripts/create_cloudflare_issuer.sh YOUR_EMAIL YOUR_CLOUDFLARE_DOMAIN"