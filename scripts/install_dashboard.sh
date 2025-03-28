#!/bin/bash
set -e

# This script installs the Kubernetes Dashboard and creates an admin user

echo "Installing Kubernetes Dashboard..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml

echo "Creating Admin Service Account for Dashboard..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF

# Generate and save the token
echo "Generating dashboard access token..."
kubectl -n kubernetes-dashboard create token admin-user > dashboard-token.txt

# Display token information
TOKEN=$(cat dashboard-token.txt)
echo
echo "Dashboard installation complete!"
echo "Token has been saved to dashboard-token.txt"
echo
echo "To start using the dashboard:"
echo
echo "1. Run the following command in a terminal:"
echo "   kubectl proxy"
echo
echo "2. Open the following URL in your browser:"
echo "   http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
echo
echo "3. Use this token to log in:"
echo
echo "$TOKEN"
echo