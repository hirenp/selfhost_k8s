# Self-Hosted Kubernetes Cluster Architecture

This document outlines the architecture of our self-hosted Kubernetes cluster on AWS with GPU support for ML workloads.

## Infrastructure Overview

Our Kubernetes cluster consists of:
- 1 Control Plane node (t3.medium)
- 1 Worker node with NVIDIA T4 GPU (g4dn.xlarge)
- Network Load Balancer for the Kubernetes API and service ingress
- Elastic IP for stable access to services

## Network Architecture Diagram

```
                                                    ┌──────────────────────┐
                                                    │                      │
                                                    │   AWS Cloud Region   │
                                                    │                      │
                                                    └──────────────────────┘
                                                              │
                                                              ▼
                          ┌───────────────────────────────────────────────────────────┐
                          │                        VPC 10.0.0.0/16                    │
                          │                                                           │
          ┌───────────────┴───────────────┐                 ┌───────────────────────┐ │
          │                               │                 │                       │ │
┌─────────▼─────────┐    ┌───────────────▼──────────┐      │   ┌─────────────────┐ │ │
│                   │    │                          │      │   │ Elastic IP      │ │ │
│   Public Subnet   │    │     Public Subnet        │      │   └────────┬────────┘ │ │
│   10.0.1.0/24     │    │     10.0.2.0/24          │      │            │          │ │
│                   │    │                          │      │   ┌────────▼────────┐ │ │
│ ┌───────────────┐ │    │ ┌──────────────────────┐ │      │   │ Network Load   │ │ │
│ │ Control Plane │ │    │ │  Worker Node w/GPU   │ │      │   │ Balancer       │ │ │
│ │ t3.medium     │ │    │ │  g4dn.xlarge         │ │      │   └────────┬────────┘ │ │
│ │               │◄┼────┼─┼─────────────────────►│ │      │            │          │ │
│ │ kube-apiserver│ │    │ │ kubelet              │ │      │            │          │ │
│ │ etcd          │ │    │ │ NVIDIA GPU Driver    │ │      │            │          │ │
│ │ scheduler     │ │    │ │ containerd           │ │      │            │          │ │
│ │ controller-mgr│ │    │ │ NVIDIA Runtime       │ │      │            │          │ │
│ └───────────────┘ │    │ │                      │ │      │            │          │ │
│         ▲         │    │ │ ┌──────────────────┐ │ │      │            │          │ │
│         │         │    │ │ │ Ingress NGINX    │◄┼─┼──────┼────────────┘          │ │
│         │         │    │ │ │ Controller       │ │ │      │                       │ │
│         │         │    │ │ └──────────────────┘ │ │      │                       │ │
│         │         │    │ │                      │ │      │                       │ │
│         │         │    │ │ ┌──────────────────┐ │ │      │                       │ │
│         └─────────┼────┼─┼►│ CoreDNS          │ │ │      │                       │ │
│                   │    │ │ └──────────────────┘ │ │      │                       │ │
│                   │    │ │                      │ │      │                       │ │
│                   │    │ │ ┌──────────────────┐ │ │      │                       │ │
│                   │    │ │ │ Calico           │ │ │      │                       │ │
│                   │    │ │ └──────────────────┘ │ │      │                       │ │
│                   │    │ │                      │ │      │                       │ │
│                   │    │ │ ┌──────────────────┐ │ │      │                       │ │
│                   │    │ │ │ Ghibli App (Pod) │ │ │      │                       │ │
│                   │    │ │ │ w/GPU Access     │ │ │      │                       │ │
│                   │    │ │ └──────────────────┘ │ │      │                       │ │
│                   │    │ └──────────────────────┘ │      │                       │ │
└───────────────────┘    └─────────────────────────┘      └───────────────────────┘ │
                          │                                                           │
                          └───────────────────────────────────────────────────────────┘
                                                │
                                                ▼
                          ┌─────────────────────────────────────────┐
                          │                                         │
                          │               Internet                  │
                          │                                         │
                          └─────────────────────────────────────────┘
```

## Key Components

### Compute Resources

- **Control Plane**: t3.medium instance (2 vCPU, 4GB RAM)
  - Runs: kube-apiserver, etcd, controller-manager, scheduler
  - Located in an Auto Scaling Group for recovery

- **Worker Node**: g4dn.xlarge instance
  - 4 vCPUs, 16GB RAM, 1 NVIDIA T4 GPU (16GB VRAM)
  - Runs: kubelet, kube-proxy, containerd, calico, ingress-nginx
  - Located in an Auto Scaling Group for recovery

### Network Layer

- **Pod Networking**: Calico CNI (10.244.0.0/16)
  - Uses VXLAN encapsulation between subnets
  - Provides network policies for security

- **Service Networking**: Kubernetes Services (10.96.0.0/12)
  - ClusterIP services for internal communication
  - LoadBalancer services via AWS Load Balancer Controller

- **Ingress**: NGINX Ingress Controller
  - Deployed on the worker node
  - Exposed via AWS Network Load Balancer
  - TLS termination with Let's Encrypt certificates via cert-manager

## Ghibli Application

Our main application is a GPU-accelerated image transformer that converts regular photos to Ghibli-style animations.

### Application Architecture

- **Frontend**: Simple HTML/CSS/JS for image upload and display
- **Backend**: Flask application with PyTorch
- **GPU Integration**: Uses CUDA for tensor operations
- **Deployment**: Kubernetes pod with GPU resource request

### Network Flow

```
User Request → 
  AWS NLB (443) → 
    Ingress NGINX → 
      Ghibli Service → 
        Ghibli Pod (w/GPU) →
          Response
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

## Monitoring Infrastructure

Our cluster includes a comprehensive monitoring stack providing visibility into all aspects of the system:

### Kubernetes Dashboard
- Official Kubernetes web UI (v2.7.0)
- Provides visualization of all cluster resources
- Secure access via token-based authentication
- Admin service account with cluster-admin role
- Access through secure kubectl proxy connection

### Prometheus Monitoring
- Deployed via kube-prometheus-stack Helm chart
- Collects metrics from multiple sources:
  - Kubernetes components (API server, scheduler, etc.)
  - Node exporters (CPU, memory, disk utilization)
  - Container metrics
  - NVIDIA GPU metrics (utilization, memory, temperature)
- Custom scrape configurations for application metrics
- Alert manager integration for notification
- Retention configuration for historical data

### Grafana Dashboards
- Pre-configured with Prometheus data source
- Multiple dashboard configurations:
  - Kubernetes cluster overview
  - Node resource utilization
  - Pod resource consumption
  - GPU performance metrics
  - Network traffic visualization
- Default dashboards extended with application-specific panels
- User-friendly interface with templating and variables

### Automated Port Forwarding
- Background process management for monitoring services
- Automatic token retrieval for authentication
- Status tracking for running port forwards
- Unified interface for starting/stopping monitoring access

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
| Control Plane | 1 x t3.medium | ~$30 |
| Worker Nodes | 1 x g4dn.xlarge | ~$38 (spot) |
| Network LB | - | ~$16.43 |
| Elastic IP | - | $0-3.60 |
| EBS Storage | gp3 | ~$15 |
| **Total** | - | **~$100/month** |

With sleep/wake functionality, costs can be reduced by up to 80% during inactive periods.

## Challenges and Lessons Learned

Throughout the development of this self-hosted Kubernetes cluster, we encountered several significant challenges that provide valuable insights for similar projects.

### GPU Support Complexity

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

### Networking Challenges

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

### Port Forwarding and Ingress Complexities

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

### Node Identity and Join Process

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

## Configuration Management

Our project employs a multi-layered approach to configuration management, using different tools at different layers of the stack based on their strengths.

### Terraform for Infrastructure

We use Terraform to manage all AWS infrastructure components:

- **Core Infrastructure**: VPC, subnets, security groups, and internet gateways
- **Compute Resources**: EC2 instances via Auto Scaling Groups for both control plane and worker nodes
- **Network Components**: Elastic IP allocation, Network Load Balancer setup
- **IAM Configuration**: Roles and policies for AWS Load Balancer Controller and worker nodes

Terraform was chosen for infrastructure management because it:
- Provides declarative configuration for AWS resources
- Maintains state tracking for complex dependencies
- Supports incremental changes without full rebuilds
- Allows versioning of infrastructure code in git
- Enables modular resource organization (modules directory)

Key Terraform modules in our setup:
- **Main infrastructure**: `/terraform/main.tf` defines the main cluster components
- **Load balancer controller**: `/terraform/modules/lb-controller/main.tf` configures the AWS Load Balancer Controller integration
- **Node initialization**: Templates in `/terraform/scripts/` for both control plane and worker nodes

### Helm for Kubernetes Applications

We use Helm charts for deploying complex Kubernetes applications:

- **Monitoring Stack**: kube-prometheus-stack chart for Prometheus, Grafana, and AlertManager
- **Ingress Controller**: nginx-ingress chart for the NGINX ingress controller
- **Certificate Management**: cert-manager chart for TLS automation

Helm was selected because it:
- Packages complex multi-resource applications into single deployable units
- Provides version management for Kubernetes manifests
- Supports configuration value overrides for different environments
- Handles upgrades and rollbacks for application lifecycle
- Manages dependencies between Kubernetes components

### Shell Scripts for Orchestration and Glue

Shell scripts serve as the orchestration layer and glue between different components:

- **Installation Scripts**: `/scripts/` directory contains individual component installers
- **Cluster Management**: `/scripts/manage_cluster.sh` for sleep/wake and status functionality
- **Monitoring Setup**: `/scripts/manage_monitoring.sh` for dashboard and metrics installation
- **Access Management**: `/scripts/access_dashboard.sh` for automated port forwarding
- **Application Deployment**: `/ghibli-app/deploy.sh` for building and deploying the GPU application

We chose shell scripts because they:
- Provide a simple interface for complex operations
- Integrate tool outputs across different systems (Terraform, kubectl, AWS CLI)
- Allow for error handling and recovery procedures
- Can be easily extended with new functionality
- Support both automation and interactive usage

### Kubernetes Manifests for Application Configuration

For application-specific configuration, we use direct Kubernetes manifests:

- **Ghibli Application**: `/ghibli-app/k8s/` directory contains deployment, service, and ingress definitions
- **TLS Configuration**: Custom ClusterIssuer resources for cert-manager
- **Network Policies**: Calico policy definitions

Raw manifests were used here because they:
- Provide precise control over application-specific resources
- Are easier to understand for simpler deployments
- Can be version-controlled directly with the application code
- Serve as educational examples of Kubernetes resource configuration

### Makefile as User Interface

The Makefile serves as a unified command interface that orchestrates all these tools:

- Provides consistent commands for common operations
- Hides implementation details from end users
- Ensures correct execution order for dependent operations
- Improves project learnability with self-documented commands

This layered approach to configuration management allows us to use the right tool for each job while maintaining a cohesive system that can be managed as a whole.

## Future Enhancements

Planned improvements include:

1. **Security**: This is a basic setup where we've not fully implemented security best practices
2. **Horizontal Pod Autoscaling**: Dynamic scaling based on GPU utilization
3. **CI/CD Pipeline**: Automated deployment workflow
4. **Monitoring Enhancements**: Set up focused alerts and more comprehensive metrics, tracing, and logging
5. **GitOps Adoption**: Moving toward a GitOps model with tools like ArgoCD or Flux