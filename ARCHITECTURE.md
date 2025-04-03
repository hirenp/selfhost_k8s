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

## 11. Challenges and Lessons Learned

Throughout the development of this self-hosted Kubernetes cluster, we encountered several significant challenges that provide valuable insights for similar projects.

### 11.1 GPU Support Complexity

Integrating NVIDIA GPUs with Kubernetes proved challenging due to:

- **Version Compatibility**: Finding compatible versions of NVIDIA drivers, CUDA, container runtime, and Kubernetes components was a delicate balancing act
- **Driver Installation**: The Ubuntu 22.04 installation required specific versions of supporting libraries (libtinfo5, libncurses5) that weren't in default repositories
- **Container Runtime Configuration**: Configuring containerd with NVIDIA runtime support required careful JSON configuration and runtime class definition
- **Kernel Module Management**: Ensuring NVIDIA kernel modules loaded properly at boot required additional persistence configuration

**Solution**: We implemented a comprehensive worker node initialization script that:
1. Installs exact versions of required libraries
2. Downloads packages from appropriate sources
3. Configures containerd with proper NVIDIA runtime handlers
4. Tests for GPU visibility with verification steps

### 11.2 Networking Challenges

The initial Flannel CNI implementation faced several issues:

- **Pod-to-Pod Communication**: Inconsistent connectivity between pods across nodes
- **DNS Resolution Failures**: CoreDNS pods experienced intermittent connectivity issues
- **Service Accessibility**: ClusterIP services sometimes unreachable from certain nodes
- **Network Policy Support**: Limited support for network policies needed for security

**Solution**: Migrating to Calico CNI resolved these issues by providing:
1. More reliable pod networking with VXLAN encapsulation
2. Better diagnostic tools for troubleshooting
3. Robust network policy implementation
4. Improved performance with optimized data paths

### 11.3 Port Forwarding and Ingress Complexities

Exposing applications externally presented unique challenges:

- **NodePort Limitations**: Default port range (30000-32767) required non-standard URLs
- **iptables Conflicts**: Calico's iptables rules often conflicted with manual port forwarding
- **Connection Resets**: TCP connections to port 80 were being reset despite proper forwarding rules
- **Certificate Management**: TLS certificate handling required special DNS validation setup

**Solution**: We implemented a layered approach:
1. Custom iptables rules inserted with proper precedence relative to Calico rules
2. hostPort configuration in the ingress controller deployment
3. Integration with cert-manager for automated TLS certificate management
4. Elastic IP association for stable external addressing

### 11.4 Node Identity and Join Process

Kubernetes cluster formation had several failure points:

- **Hostname Uniqueness**: Default EC2 hostname pattern caused duplicate hostnames during scaling
- **Certificate Distribution**: Secure distribution of cluster certificates to new control plane nodes
- **Join Command Access**: Worker nodes needed secure access to valid join tokens
- **Node Recovery**: Rejoining nodes after instance replacement or reboots

**Solution**: Our approach included:
1. Using EC2 instance IDs in hostnames for guaranteed uniqueness
2. Implementing kubeadm certificate upload and download process
3. Creating a multi-stage join process with fallback mechanisms
4. Distributing SSH keys to allow secure node-to-node communication

### 11.5 Statelessness and Persistence

Maintaining cluster state through scale-down/up cycles was challenging:

- **Configuration Persistence**: Preserving cluster configuration during sleep/wake cycles
- **Elastic IP Management**: Ensuring consistent IP addressing for external access
- **Service Reconfiguration**: Reinstalling ingress controllers without changing external endpoints
- **Credentials Management**: Preserving secrets and credentials across cluster rebuilds

**Solution**: We designed a comprehensive state management approach:
1. Using persistent EBS volumes for critical data
2. Creating a "prevent_destroy" configuration for Elastic IPs
3. Implementing proper node initialization scripts that handle rejoining
4. Automating the reinstallation of critical components after wakeup

## 12. Future Enhancements

Planned improvements include:

1. **Security**: This is a very basic setup where we've not looked at security/privacy
2. **Horizontal Pod Autoscaling**: Dynamic scaling based on GPU utilization
3. **CI/CD Pipeline**: Automated deployment workflow
4. **Monitoring**: Set up focused alerts and also useful metrics, tracing etc. Also make the existing Observability stack more robust.
