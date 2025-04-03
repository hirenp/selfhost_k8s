#!/bin/bash
set -e

# Check command-line arguments
if [ "$#" -lt 2 ]; then
  echo "Usage: $0 YOUR_EMAIL YOUR_CLOUDFLARE_DOMAIN"
  echo "Example: $0 admin@example.com example.com"
  exit 1
fi

EMAIL=$1
DOMAIN=$2

# Verify that Cloudflare API token secret exists
if ! kubectl get secret cloudflare-api-token -n cert-manager &>/dev/null; then
  echo "Error: Cloudflare API token secret not found."
  echo "Create it first with:"
  echo "kubectl create secret generic cloudflare-api-token -n cert-manager --from-literal=api-token=YOUR_CLOUDFLARE_API_TOKEN"
  exit 1
fi

# Create a ClusterIssuer for Let's Encrypt with Cloudflare DNS
echo "Creating ClusterIssuer for Let's Encrypt using Cloudflare DNS..."

cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: ${EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - dns01:
        cloudflare:
          email: ${EMAIL}
          apiTokenSecretRef:
            name: cloudflare-api-token
            key: api-token
      selector:
        dnsZones:
        - "${DOMAIN}"
EOF

echo
echo "ClusterIssuer has been created for ${DOMAIN} with email ${EMAIL}"
echo
echo "Now, create ingress resources for your services with annotations:"
echo "annotations:"
echo "  kubernetes.io/ingress.class: nginx"
echo "  cert-manager.io/cluster-issuer: letsencrypt-prod"
echo
echo "You'll need to create DNS records in Cloudflare pointing to your ingress controller's Load Balancer."
echo "To get the Load Balancer IP/hostname: kubectl get svc -n ingress-nginx ingress-nginx-controller"
echo
echo "Let's create the ingress resources for monitoring services:"
echo "./scripts/create_monitoring_ingress.sh ${DOMAIN}"