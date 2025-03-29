#!/bin/bash
set -e

# Use doandlearn.app as the domain
DOMAIN="doandlearn.app"
BASE_PATH="/selfhost_k8s"

echo "Using domain: $DOMAIN"

# Verify that the necessary components are installed
if ! kubectl get namespace ingress-nginx &>/dev/null; then
  echo "Error: NGINX Ingress Controller not found. Install it first with ./scripts/install_ingress.sh"
  exit 1
fi

echo "Creating ingress resources for monitoring services with path-based routing..."

# Create a namespace for basic auth if it doesn't exist
kubectl create namespace basic-auth 2>/dev/null || true

# Create a basic auth secret for protecting the dashboards
if ! kubectl get secret dashboard-auth -n basic-auth &>/dev/null; then
  echo "Creating basic auth credentials for dashboard access..."
  
  # Generate a random password
  PASSWORD=$(openssl rand -base64 12)
  
  # Create htpasswd file
  htpasswd_output=$(htpasswd -nb admin "$PASSWORD" 2>/dev/null || echo "admin:$(openssl passwd -apr1 $PASSWORD)")
  
  # Create the secret
  kubectl create secret generic dashboard-auth \
    --namespace basic-auth \
    --from-literal=auth="$htpasswd_output" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  echo "Created basic auth credentials:"
  echo "Username: admin"
  echo "Password: $PASSWORD"
  echo "Please save these credentials securely!"
fi

# Check if cert-manager is installed
CERT_MANAGER_EXISTS=$(kubectl get namespace cert-manager --no-headers 2>/dev/null || echo "")
if [ ! -z "$CERT_MANAGER_EXISTS" ] && kubectl get clusterissuer letsencrypt-prod &>/dev/null; then
  USE_TLS=true
  TLS_ANNOTATIONS="
    cert-manager.io/cluster-issuer: letsencrypt-prod"
  echo "Using TLS with Let's Encrypt"
else
  USE_TLS=false
  TLS_ANNOTATIONS=""
  echo "cert-manager or ClusterIssuer not found, TLS will not be configured"
fi

# Create a single ingress resource for all monitoring services
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: monitoring-ingress
  namespace: ingress-nginx
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/auth-realm: "Authentication Required"
    nginx.ingress.kubernetes.io/auth-secret: "basic-auth/dashboard-auth"
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/rewrite-target: /\$2$TLS_ANNOTATIONS
spec:
EOF

if [ "$USE_TLS" = true ]; then
  cat <<EOF | kubectl apply -f -
  tls:
  - hosts:
    - ${DOMAIN}
    secretName: monitoring-tls
EOF
fi

cat <<EOF | kubectl apply -f -
  rules:
  - host: ${DOMAIN}
    http:
      paths:
EOF

# Check if Kubernetes Dashboard is installed
DASHBOARD_EXISTS=$(kubectl get ns kubernetes-dashboard --no-headers 2>/dev/null || echo "")
if [ ! -z "$DASHBOARD_EXISTS" ]; then
  echo "Adding Kubernetes Dashboard to ingress..."
  
  # Create a service in the ingress-nginx namespace to proxy to kubernetes-dashboard
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: dashboard-proxy
  namespace: ingress-nginx
spec:
  ports:
  - port: 443
    targetPort: 8443
    protocol: TCP
    name: https
  selector:
    k8s-app: kubernetes-dashboard
EOF

  # Add dashboard path to ingress
  cat <<EOF | kubectl apply -f -
      - path: ${BASE_PATH}/dashboard(/|$)(.*)
        pathType: Prefix
        backend:
          service:
            name: kubernetes-dashboard
            port:
              number: 443
EOF

  echo "Kubernetes Dashboard will be available at: https://${DOMAIN}${BASE_PATH}/dashboard/"
fi

# Check if Grafana is installed
GRAFANA_EXISTS=$(kubectl get deployment -n monitoring prometheus-grafana --no-headers 2>/dev/null || echo "")
if [ ! -z "$GRAFANA_EXISTS" ]; then
  echo "Adding Grafana to ingress..."
  
  # Add grafana path to ingress
  cat <<EOF | kubectl apply -f -
      - path: ${BASE_PATH}/grafana(/|$)(.*)
        pathType: Prefix
        backend:
          service:
            name: prometheus-grafana
            port:
              number: 80
EOF

  echo "Grafana will be available at: https://${DOMAIN}${BASE_PATH}/grafana/"
  echo "Default Grafana login: admin / admin"
  
  # Configure Grafana root URL
  kubectl patch deployment -n monitoring prometheus-grafana --type=json \
    -p='[{"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value": {"name": "GF_SERVER_ROOT_URL", "value": "https://'${DOMAIN}${BASE_PATH}'/grafana"}}]'
fi

# Check if Prometheus is installed
PROMETHEUS_EXISTS=$(kubectl get statefulset -n monitoring prometheus-kube-prometheus-prometheus --no-headers 2>/dev/null || echo "")
if [ ! -z "$PROMETHEUS_EXISTS" ]; then
  echo "Adding Prometheus to ingress..."
  
  # Add prometheus path to ingress
  cat <<EOF | kubectl apply -f -
      - path: ${BASE_PATH}/prometheus(/|$)(.*)
        pathType: Prefix
        backend:
          service:
            name: prometheus-kube-prometheus-prometheus
            port:
              number: 9090
EOF

  echo "Prometheus will be available at: https://${DOMAIN}${BASE_PATH}/prometheus/"
fi

echo
echo "Ingress resources have been created!"
echo
echo "To complete the setup:"
echo "1. Get the external IP/hostname of your NGINX Ingress controller:"
echo "   kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
echo
echo "2. In your Cloudflare DNS settings, add an A or CNAME record for ${DOMAIN} pointing to the ingress controller IP/hostname"
echo
echo "3. Access your services at:"
if [ ! -z "$DASHBOARD_EXISTS" ]; then echo "   - Kubernetes Dashboard: https://${DOMAIN}${BASE_PATH}/dashboard/"; fi
if [ ! -z "$GRAFANA_EXISTS" ]; then echo "   - Grafana: https://${DOMAIN}${BASE_PATH}/grafana/"; fi
if [ ! -z "$PROMETHEUS_EXISTS" ]; then echo "   - Prometheus: https://${DOMAIN}${BASE_PATH}/prometheus/"; fi
echo
echo "4. Use the basic auth credentials you saved earlier to log in"