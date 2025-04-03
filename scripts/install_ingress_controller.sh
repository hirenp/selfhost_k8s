#!/bin/bash
set -e

echo "Installing simplified NGINX Ingress Controller..."

# First, clean up any existing ingress-nginx namespace
kubectl delete namespace ingress-nginx --ignore-not-found

# Create namespace first
kubectl create namespace ingress-nginx

# Create the RBAC configuration file
cat > /tmp/ingress-rbac.yaml << EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nginx-ingress-serviceaccount
  namespace: ingress-nginx
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: nginx-ingress-clusterrole
rules:
  - apiGroups:
      - ""
    resources:
      - configmaps
      - endpoints
      - nodes
      - pods
      - secrets
      - services
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - nodes
    verbs:
      - get
  - apiGroups:
      - ""
    resources:
      - services
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - networking.k8s.io
    resources:
      - ingresses
      - ingressclasses
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - events
    verbs:
      - create
      - patch
  - apiGroups:
      - networking.k8s.io
    resources:
      - ingresses/status
    verbs:
      - update
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: nginx-ingress-clusterrole-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: nginx-ingress-clusterrole
subjects:
  - kind: ServiceAccount
    name: nginx-ingress-serviceaccount
    namespace: ingress-nginx
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: nginx-ingress-role
  namespace: ingress-nginx
rules:
  - apiGroups:
      - ""
    resources:
      - namespaces
    verbs:
      - get
  - apiGroups:
      - ""
    resources:
      - configmaps
      - pods
      - secrets
      - endpoints
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - services
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - networking.k8s.io
    resources:
      - ingresses
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - events
    verbs:
      - create
      - patch
  - apiGroups:
      - networking.k8s.io
    resources:
      - ingresses/status
    verbs:
      - update
  - apiGroups:
      - ""
    resources:
      - configmaps
    verbs:
      - create
  - apiGroups:
      - ""
    resources:
      - configmaps
    verbs:
      - update
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: nginx-ingress-role-binding
  namespace: ingress-nginx
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: nginx-ingress-role
subjects:
  - kind: ServiceAccount
    name: nginx-ingress-serviceaccount
    namespace: ingress-nginx
EOF

kubectl apply -f /tmp/ingress-rbac.yaml

cat > /tmp/ingress-simple.yaml << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ingress-nginx
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-ingress-controller
  namespace: ingress-nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-ingress
  template:
    metadata:
      labels:
        app: nginx-ingress
    spec:
      serviceAccountName: nginx-ingress-serviceaccount
      containers:
      - name: nginx-ingress-controller
        image: k8s.gcr.io/ingress-nginx/controller:v1.2.0
        args:
        - /nginx-ingress-controller
        - --publish-service=ingress-nginx/ingress-nginx-controller
        - --election-id=ingress-controller-leader
        - --ingress-class=nginx
        - --configmap=ingress-nginx/ingress-nginx-controller
        ports:
        - name: http
          containerPort: 80
          hostPort: 32245
        - name: https
          containerPort: 443
          hostPort: 32479
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
---
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
spec:
  type: NodePort
  ports:
  - name: http
    port: 80
    targetPort: 80
    nodePort: 32245
    protocol: TCP
  - name: https
    port: 443
    targetPort: 443
    nodePort: 32479
    protocol: TCP
  selector:
    app: nginx-ingress
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
EOF

# Apply the simplified ingress configuration
kubectl apply -f /tmp/ingress-simple.yaml

# Determine the path to terraform directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"

# Get the Elastic IP public IP
EIP_PUBLIC_IP=$(terraform -chdir="$TERRAFORM_DIR" output -raw ingress_eip_public_ip 2>/dev/null || echo "")

echo "Waiting for NGINX Ingress Controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app=nginx-ingress \
  --timeout=180s || echo "Timeout waiting for ingress controller - check manually with 'kubectl get pods -n ingress-nginx'"

echo 
echo "NGINX Ingress Controller has been installed successfully!"
if [ -n "$EIP_PUBLIC_IP" ]; then
  echo "Public IP: $EIP_PUBLIC_IP"
  echo
  echo "To use it with your domain, create a DNS record for your domain pointing to this public IP"
  echo "For the Ghibli app, create an A record for ghibli.doandlearn.app pointing to $EIP_PUBLIC_IP"
else
  echo "No Elastic IP found. You'll need to use the worker node's public IP with the nodePort (32245 for HTTP, 32479 for HTTPS)"
fi