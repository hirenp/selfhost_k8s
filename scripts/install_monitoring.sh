#!/bin/bash
set -e

# This script installs Prometheus and Grafana for monitoring

echo "Installing Helm if not already installed..."
if ! command -v helm &> /dev/null; then
  echo "Helm not found, installing..."
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  echo "Helm is already installed"
fi

# Add the Prometheus Helm repository
echo "Adding Prometheus Helm repository..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install kube-prometheus-stack (includes Prometheus, Grafana, and Alertmanager)
echo "Installing Prometheus and Grafana..."
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword=admin \
  --set prometheus.service.type=ClusterIP

echo
echo "Monitoring installation complete!"
echo
echo "To access Grafana:"
echo "1. Run the following command in a terminal:"
echo "   kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
echo
echo "2. Open the following URL in your browser:"
echo "   http://localhost:3000"
echo
echo "3. Log in with these credentials:"
echo "   Username: admin"
echo "   Password: admin"
echo
echo "To access Prometheus:"
echo "1. Run the following command in a terminal:"
echo "   kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090"
echo
echo "2. Open the following URL in your browser:"
echo "   http://localhost:9090"
echo