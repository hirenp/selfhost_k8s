# Self-Hosted Kubernetes Cluster Architecture

This document details the specific architecture and implementation of our self-hosted Kubernetes cluster on AWS, built with Terraform for GPU-accelerated workloads.

## 1. Infrastructure Overview

Our cluster consists of:
- 1 Control Plane nodes in an Auto Scaling Group for high availability
- 1 Worker nodes with NVIDIA T4 GPUs (g4dn.xlarge) in an Auto Scaling Group
- Network Load Balancer for the Kubernetes API
- Elastic IP for stable access to services 
- VPC with security groups for network isolation

## 2. Key Components

### 2.1 Networking Infrastructure

- **Calico CNI**: Used for pod networking with encapsulation mode set to VXLANCrossSubnet
- **Pod CIDR**: 10.244.0.0/16 with 26-bit block size
- **Service CIDR**: 10.96.0.0/12 (Kubernetes default)
- **Static IP**: Elastic IP configured with `prevent_destroy = true` for persistent addressing

### 2.2 Compute Resources

- **Control Plane Nodes**: t3.medium instances (cost-optimized for control functions)
- **Worker Nodes**: g4dn.xlarge instances with NVIDIA T4 GPUs
  - Each with 4 vCPUs, 16GB RAM, and 1 NVIDIA T4 GPU (16GB VRAM)

### 2.3 Software Components

- **Kubernetes Version**: 1.29.3
- **Container Runtime**: containerd with NVIDIA runtime for GPU support
- **Control Plane Components**: 
  - API Server, Controller Manager, Scheduler, etcd
  - Calico Operator for network management
- **Worker Components**:
  - kubelet with systemd cgroup driver
  - NVIDIA Device Plugin for GPU orchestration
  - Automatic port forwarding for ingress traffic

## 3. Network Architecture

### 3.1 Calico Implementation

Our cluster uses Calico instead of Flannel for enhanced networking capabilities:

```yaml
# Applied configuration:
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: 10.244.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
```

Calico provides:
- More fine-grained network policies than Flannel
- Better performance and debugging capabilities
- VXLANCrossSubnet encapsulation for traffic between different subnets
- NAT for outgoing traffic

### 3.2 Ingress Configuration

- **NGINX Ingress Controller**:
  - Deployed with hostPort:32245 (HTTP) and hostPort:32479 (HTTPS)
  - Configured as NodePort services for external access
  - Static Elastic IP associated with a worker node

- **Port Forwarding**:
  - iptables rules configured on worker nodes for port 80→32245 and 443→32479
  - Rules applied at boot via user_data_worker.sh:
    ```bash
    # Clear existing port forwarding rules for 80/443
    iptables -t nat -F PREROUTING
    
    # Add new rules
    iptables -t nat -I PREROUTING 1 -p tcp --dport 80 -j REDIRECT --to-port 32245
    iptables -t nat -I PREROUTING 2 -p tcp --dport 443 -j REDIRECT --to-port 32479
    ```

## 4. GPU Infrastructure

### 4.1 Hardware Configuration

- **Instance Type**: g4dn.xlarge with NVIDIA T4 GPU
- **GPU Memory**: 16GB GDDR6
- **CUDA Cores**: 2,560
- **Tensor Cores**: 320

### 4.2 Software Stack

- **NVIDIA Drivers**: 535.xx series
- **CUDA Version**: 12.1
- **Container Runtime**: containerd with nvidia-container-runtime
- **Kubernetes Integration**: NVIDIA Device Plugin

### 4.3 GPU Enablement Process

The worker node initialization script:
1. Installs NVIDIA drivers and CUDA libraries
2. Configures the nvidia-container-runtime for containerd
3. Sets up the device plugin directory with proper permissions
4. Adds RuntimeClass for GPU workloads

## 5. Ghibli Application Deployment

Our first GPU-accelerated application is a Ghibli-style image transformer:

### 5.1 Application Architecture

- **Frontend**: HTML/CSS/JavaScript for image upload and transformation
- **Backend**: Flask application running PyTorch inference
- **Inference**: GPU-accelerated deep learning model based on AnimeGANv2
- **Deployment**: Single replica pod with GPU resource request

### 5.2 Kubernetes Resources

- **Deployment**: 
  - Requests 1 NVIDIA GPU
  - Uses NVIDIA RuntimeClass
  - Runs in hostNetwork mode for direct GPU access

- **Service**:
  - ClusterIP service exposing port 80 → container port 5000
  
- **Ingress**:
  - HTTPS-enabled with Let's Encrypt certificates
  - Domain: ghibli.doandlearn.app

## 6. TLS & Certificate Management

### 6.1 Certificate Manager Setup

- **cert-manager** deployed for automated certificate handling
- **ClusterIssuer** configured for Let's Encrypt production
- **DNS01 validation** using Cloudflare API

### 6.2 Certificate Workflow

1. Ingress resources request certificates via annotations
2. cert-manager creates Certificate resources
3. DNS validation occurs via Cloudflare
4. TLS certificates stored as Kubernetes secrets
5. Ingress controller serves HTTPS using these certificates

## 7. Cost Optimization

### 7.1 Sleep/Wake Functionality

The cluster includes scripts for scaling down when not in use:

- **Sleep Mode**: 
  - Scales EC2 instances to 0
  - Removes the Network Load Balancer
  - Preserves Elastic IP allocation
  - Retains all Kubernetes state (etcd data)

- **Wake Mode**:
  - Restores instances to desired count
  - Recreates the Network Load Balancer
  - Re-attaches the Elastic IP

### 7.2 Cost Breakdown

| Component | Type | Monthly Cost |
|-----------|------|--------------|
| Control Plane | 2 x t3.medium | ~$60 |
| Worker Nodes | 3 x g4dn.xlarge | ~$114 (spot) |
| Network LB | - | ~$16.43 |
| Elastic IP | - | $0-3.60 |
| EBS Storage | gp3 | ~$30 |
| **Total** | - | **~$220/month** |

With sleep/wake functionality, costs can be reduced by up to 80% during inactive periods.

## 8. High Availability Design

### 8.1 Control Plane Redundancy

- **Multi-Node Setup**: Two control plane nodes for redundancy
- **Leader Election**: Kubernetes components use leader election
- **etcd Cluster**: Distributed across control plane nodes
- **Certificate Sharing**: Secured with kubeadm certificate upload

### 8.2 Worker Node Resilience

- **Auto Scaling Groups**: Automatically replace failed nodes
- **Node Join Process**: Multi-stage with fallback mechanisms:
  ```bash
  # Try to get fresh join command from control plane nodes
  # If that fails, use a fallback mechanism with discovery token
  if [ -z "$JOIN_COMMAND" ]; then
    JOIN_COMMAND="kubeadm join $CONTROL_PLANE_LB:6443 --token abcdef.0123456789abcdef --discovery-token-unsafe-skip-ca-verification --node-name $HOSTNAME"
  fi
  ```

### 8.3 Static IP Preservation

- **Elastic IP Strategy**:
  - Configured with `prevent_destroy = true` in Terraform
  - Persists across cluster destroy/create cycles
  - Ensures services maintain the same public IP address
  - Simplifies DNS configuration

## 9. Monitoring and Observability

### 9.1 Monitoring Infrastructure

Our cluster monitoring stack consists of:

- **Kubernetes Dashboard**: Visualization of cluster resources and state
- **Prometheus**: Time-series metrics collection and storage
- **Grafana**: Metrics visualization and dashboarding
- **kube-prometheus-stack**: Comprehensive monitoring for Kubernetes components

### 9.2 Kubernetes Dashboard

- Official Kubernetes web UI (v2.7.0)
- Displays cluster resources, deployments, and workloads
- Secure access via token-based authentication
- Admin service account with cluster-admin ClusterRole
- Accessible via kubectl proxy at:
  ```
  http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/
  ```

### 9.3 Prometheus Monitoring

- Deployed using Helm chart from prometheus-community
- Collects metrics from:
  - Kubernetes components (kubelet, API server, etc.)
  - Node-level metrics (CPU, memory, disk)
  - Container metrics
  - Calico networking components
  - NVIDIA GPU metrics
- Runs in dedicated `monitoring` namespace
- Configured with ClusterIP service for internal access
- Accessible via port-forwarding:
  ```
  kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
  ```

### 9.4 Grafana Dashboard

- Deployed as part of kube-prometheus-stack
- Pre-configured with Prometheus data source
- Default dashboards for:
  - Kubernetes cluster overview
  - Node resources
  - Pod resources
  - GPU utilization
- Accessible via port-forwarding:
  ```
  kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
  ```
- Default credentials: admin/admin

### 9.5 Logging and Debugging

- **System Logs**: systemd journal for host-level components
- **Container Logs**: Accessible via kubectl logs
- **Network Debugging**:
  - Calico diagnostic tools
  - tcpdump and iptables inspection
  - Connection tracking with conntrack
- **GPU Monitoring**: 
  - nvidia-smi for device status
  - Prometheus metrics for utilization tracking

## 10. Automation and Management

### 10.1 Makefile Infrastructure

The project uses a comprehensive Makefile to streamline common operations. This Makefile simplifies cluster management with targets for:

- Initial infrastructure provisioning
- Kubernetes component installation
- Cluster sleep/wake operations
- Monitoring setup
- Status checking and diagnostics

Common operations can be performed with simple commands like:
- `make apply` - Deploy the cluster infrastructure
- `make install-gpu-plugin` - Configure GPU support
- `make sleep` - Scale down the cluster for cost savings
- `make monitoring-all` - Deploy complete monitoring stack

### 10.2 Application Deployment Automation

The Ghibli application uses its own deployment script (`deploy.sh`) to automate the build and deployment process. This script handles:

- Cross-platform Docker image building (for amd64 target)
- Dynamic image tagging with timestamps
- Automatic Kubernetes manifest updates
- Resource application and deployment validation

Using these automation tools significantly reduces operational overhead and ensures consistent deployments across environments.

## 11. Future Enhancements

Planned improvements include:

1. **Security**: This is a very basic setup where we've not looked at security/privacy.
2. **Horizontal Pod Autoscaling**: Dynamic scaling based on GPU utilization
3. **CI/CD Pipeline**: Automated deployment workflow
4. **Monitoring**: We need to setup focused alerts and also useful metrics, tracing etc.
