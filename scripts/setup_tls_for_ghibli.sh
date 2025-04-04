#!/bin/bash
set -e

# Check command-line arguments
if [ "$#" -lt 2 ]; then
  echo "Usage: $0 YOUR_EMAIL YOUR_CLOUDFLARE_API_TOKEN"
  echo "Example: $0 admin@example.com your-cloudflare-api-token"
  exit 1
fi

EMAIL=$1
API_TOKEN=$2
DOMAIN="doandlearn.app"
SUBDOMAIN="ghibli.${DOMAIN}"

# Create the Cloudflare API token secret
echo "Creating Cloudflare API token secret..."
kubectl create secret generic cloudflare-api-token -n cert-manager --from-literal=api-token="${API_TOKEN}" --dry-run=client -o yaml | kubectl apply -f -

# Run the cloudflare issuer script
echo "Creating Let's Encrypt issuer with Cloudflare DNS..."
./scripts/create_cloudflare_issuer.sh "${EMAIL}" "${DOMAIN}"

# Apply the ingress resource
echo "Creating ingress resource for the Ghibli app..."
kubectl apply -f ./ghibli-app/k8s/ingress.yaml

# Get the current ingress controller NodePort service
INGRESS_PORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
INGRESS_HTTPS_PORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
WORKER_PUBLIC_IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=k8s-worker-node" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

# Get the ELB DNS name for the ghibli-app service
ELB_DNS=$(kubectl get svc ghibli-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo
echo "TLS setup process initiated for ${SUBDOMAIN}"
echo
echo "1. Make sure your Cloudflare DNS has an A record for ${SUBDOMAIN} pointing to ${WORKER_PUBLIC_IP}"
echo "   (Alternative: Create a CNAME record pointing to the ELB: ${ELB_DNS})"
echo
echo "2. The certificate issuance process will start automatically. Check status with:"
echo "   kubectl get certificate -n default"
echo
echo "3. Once the certificate is issued, your app will be available at:"
echo "   https://${SUBDOMAIN}"
echo
echo "4. Ingress controller details:"
echo "   HTTP Port: ${INGRESS_PORT}"
echo "   HTTPS Port: ${INGRESS_HTTPS_PORT}"
echo
echo "5. You can check the certificate status with:"
echo "   kubectl describe certificate ghibli-tls-cert"