# Self-Hosted Kubernetes on AWS (for maximum fun and some pain)

This project sets up a self-hosted Kubernetes cluster on AWS with GPU support. This README focuses on installation and operations. For architecture details, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Prerequisites

Before starting, make sure you have:

- AWS CLI configured with appropriate credentials
- Terraform installed (v1.0.0+)
- kubectl installed locally
- An SSH key pair for accessing EC2 instances

## Installation Steps

### 1. Clone and Initialize

```bash
# Clone the repository
git clone https://github.com/hirenp/selfhost_k8s.git
cd selfhost_k8s

# Generate SSH key if needed
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa_aws -N ""

# Initialize Terraform
make init
```

**Verification**: You should see "Terraform has been successfully initialized!"

### 2. Deploy Infrastructure

```bash
# Review the plan (optional)
make plan

# Deploy the infrastructure
make apply
```

**Verification**: Terraform should show successful resource creation with "Apply complete!" message.

### 3. Set Up Kubernetes Access

```bash
# Configure kubeconfig
make setup-kubeconfig
```

**Verification**: Confirm cluster access with:
```bash
kubectl get nodes
```
You should see your control plane and worker nodes (may take a few minutes to show all nodes as Ready).

### 4. Install Networking Components

```bash
# Install both Ingress Controller and AWS Load Balancer Controller
make install-networking
```

**Verification**: Check that networking components are running:
```bash
kubectl get pods -n ingress-nginx
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

### 5. Install NVIDIA GPU Plugin

```bash
make install-gpu-plugin
```

**Verification**: Verify GPU support:
```bash
kubectl get nodes -o=custom-columns=NAME:.metadata.name,GPU:.status.capacity.'nvidia\.com/gpu'
```
Worker nodes should show available GPUs.

### 6. Install Monitoring Stack

```bash
# Install Dashboard and Prometheus/Grafana
make monitoring-all
```

**Verification**: Check that monitoring components are running:
```bash
kubectl get pods -n kubernetes-dashboard
kubectl get pods -n monitoring
```

### 7. Deploy the Ghibli App

```bash
# Deploy the application with a single command
make deploy-ghibli-app
```

**Verification**: Check the deployment status:
```bash
kubectl get pods | grep ghibli
kubectl get service ghibli-app
```

### 8. Set Up TLS with cert-manager

```bash
# Install cert-manager if not already installed
make install-cert-manager

# Create a Cloudflare API token with DNS editing permissions and create a secret
kubectl create secret generic cloudflare-api-token -n cert-manager \
  --from-literal=api-token=YOUR_CLOUDFLARE_API_TOKEN

# Create the ClusterIssuer for Let's Encrypt
./scripts/create_cloudflare_issuer.sh YOUR_EMAIL doandlearn.app

# Enable TLS for the application
make enable-tls
```

After running `make enable-tls`, you'll get the AWS Load Balancer DNS name for the ingress controller. Create a CNAME record in Cloudflare that points `ghibli.doandlearn.app` to this DNS name. The application will be accessible securely at `https://ghibli.doandlearn.app` after DNS propagation completes.

## Cluster Management

### Check Cluster Status

```bash
make status
```

### Sleep Cluster (to save costs)

```bash
make sleep
```

**Verification**: Check that instances are scaled down:
```bash
aws ec2 describe-instances --filters "Name=tag:Role,Values=control-plane,worker" "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].InstanceId" --output text
```
No instances should be returned.

### Wake Up Cluster

```bash
make wakeup
```

**Verification**: Wait for nodes to become ready:
```bash
kubectl get nodes
```

After waking up, you'll need to reinstall the networking components and TLS:
```bash
make setup-kubeconfig
make install-networking
make enable-tls
```

### Access Monitoring Dashboards

```bash
make monitoring
```

This will display access instructions for Kubernetes Dashboard, Prometheus, and Grafana.

## Updating and Maintenance

### Update NVIDIA Drivers

To update NVIDIA drivers on worker nodes:

```bash
# SSH into each worker node
ssh -i ~/.ssh/id_rsa_aws ubuntu@<worker-node-ip>

# Update drivers
sudo apt update
sudo apt install --only-upgrade nvidia-driver-535
```

### Update Kubernetes Components

To update Kubernetes components, modify the version in Terraform variables and apply:

```bash
# Edit terraform/variables.tf to update k8s_version
make apply
```

## Troubleshooting

### Node Issues

If you encounter node problems:

```bash
# SSH into the problematic node
ssh -i ~/.ssh/id_rsa_aws ubuntu@<node-ip>

# Check kubelet logs
sudo journalctl -u kubelet -n 100

# Check containerd status
sudo systemctl status containerd
```

### Networking Issues

For networking problems:

```bash
# Check Calico status
kubectl -n calico-system get pods

# Verify Calico installation
kubectl get tigerastatus

# Check AWS Load Balancer Controller status
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Check Ingress Controller status
kubectl get pods -n ingress-nginx

# View LoadBalancer services
kubectl get svc -A -o wide | grep LoadBalancer

# Check TLS certificates status
kubectl get certificate -A
```

### AWS Target Group Registration Issues

If your application can't be accessed through the AWS Load Balancer:

1. Verify that worker nodes are registered with the target groups:
   ```bash
   aws elbv2 describe-target-groups --query "TargetGroups[?contains(TargetGroupName, 'ingress')]"
   ```

2. Check the registration script logs on worker nodes:
   ```bash
   ssh -i ~/.ssh/id_rsa_aws ubuntu@<worker-ip> "sudo cat /tmp/register_target_groups.log"
   ```

3. Manually trigger target registration if needed:
   ```bash
   ssh -i ~/.ssh/id_rsa_aws ubuntu@<worker-ip> "sudo /tmp/register_target_groups.sh"
   ```

### GPU Problems

For GPU-related issues:

```bash
# Check NVIDIA device plugin
kubectl get pods -n kube-system | grep nvidia

# Verify GPU detection on worker node
ssh -i ~/.ssh/id_rsa_aws ubuntu@<worker-ip> "nvidia-smi"
```

## Complete Cleanup

To remove all resources:

```bash
make destroy
```

**Note about Elastic IP**: The EIP has `prevent_destroy = true` to maintain your static IP. To destroy everything:

1. Remove the EIP from Terraform state:
   ```bash
   cd terraform
   terraform state rm aws_eip.ingress_eip
   ```

2. Destroy remaining resources:
   ```bash
   terraform destroy
   ```

3. Release the EIP manually:
   ```bash
   aws ec2 describe-addresses --filters "Name=tag:Name,Values=k8s-ingress-eip"
   aws ec2 release-address --allocation-id <allocation-id>
   ```
