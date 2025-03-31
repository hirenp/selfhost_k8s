# Kubernetes Cluster Architecture and Setup Process

This document details how our self-hosted Kubernetes cluster on AWS is architected and the process for setting it up using Terraform.

## 1. Infrastructure Overview

The cluster consists of:
- 2 Control Plane nodes for high availability
- 3 Worker nodes for running workloads
- Network Load Balancer for the Kubernetes API
- Auto Scaling Groups for automatic recovery
- VPC with security groups for network isolation

## 2. Architecture Diagram

```
                           ┌─────────────────────────────────────────────────┐
                           │                    AWS VPC                       │
                           │                                                 │
                           │  ┌─────────────────┐    ┌─────────────────┐    │
┌───────────────┐          │  │                 │    │                 │    │
│               │          │  │ Auto Scaling Group   │ Auto Scaling Group   │
│  Client /     │          │  │ ┌─────────────┐ │    │ ┌─────────────┐ │    │
│  Admin        │──────────┼─▶│ │Control Plane│ │    │ │   Worker    │ │    │
│  Workstation  │          │  │ │   Node 1    │ │    │ │   Node 1    │ │    │
│               │          │  │ └─────────────┘ │    │ └─────────────┘ │    │
└───────────────┘          │  │ ┌─────────────┐ │    │ ┌─────────────┐ │    │
        │                  │  │ │Control Plane│ │    │ │   Worker    │ │    │
        │                  │  │ │   Node 2    │ │    │ │   Node 2    │ │    │
        │                  │  │ └─────────────┘ │    │ └─────────────┘ │    │
        │                  │  │                 │    │ ┌─────────────┐ │    │
        │                  │  └─────────────────┘    │ │   Worker    │ │    │
        │                  │           ▲             │ │   Node 3    │ │    │
        │                  │           │             │ └─────────────┘ │    │
        │                  │  ┌────────┴────────┐    └─────────────────┘    │
        └──────────────────┼─▶│  Network Load   │             ▲              │
                           │  │    Balancer     │             │              │
                           │  └────────┬────────┘             │              │
                           │           │                      │              │
                           │           └──────────────────────┘              │
                           │                                                 │
                           └─────────────────────────────────────────────────┘

```

## 3. Kubernetes Components

### Control Plane Components:
- **kube-apiserver**: REST API serving as the front-end for Kubernetes control plane
- **etcd**: Consistent and highly-available key-value store for all cluster data
- **kube-controller-manager**: Runs controller processes (node controller, replication controller, etc.)
- **kube-scheduler**: Watches for newly created pods and selects nodes for them to run on
- **Flannel**: Network overlay providing the pod network

### Worker Components:
- **kubelet**: Ensures containers are running in a pod
- **kube-proxy**: Maintains network rules for service communication
- **Container runtime**: containerd for running containers

## 4. Component Architecture Diagram

```
┌─ Control Plane Node ────────────────────────────┐  ┌─ Worker Node ─────────────────────┐
│                                                 │  │                                   │
│  ┌─ Static Pods ─────────────────────────────┐  │  │  ┌─ Node Components ───────────┐  │
│  │                                           │  │  │  │                             │  │
│  │  ┌───────────────┐   ┌──────────────────┐ │  │  │  │                             │  │
│  │  │ kube-apiserver│   │ kube-scheduler   │ │  │  │  │                             │  │
│  │  └───────────────┘   └──────────────────┘ │  │  │  │                             │  │
│  │                                           │  │  │  │                             │  │
│  │  ┌───────────────┐   ┌──────────────────┐ │  │  │  │      ┌───────────────┐     │  │
│  │  │ etcd          │   │ controller-      │ │  │  │  │      │ kube-proxy    │     │  │
│  │  │               │   │ manager          │ │  │  │  │      └───────────────┘     │  │
│  │  └───────────────┘   └──────────────────┘ │  │  │  │                             │  │
│  └───────────────────────────────────────────┘  │  │  └─────────────────────────────┘  │
│                                                 │  │                                   │
│  ┌─ Node Components ─────────────────────────┐  │  │  ┌─ Container Runtime ──────────┐  │
│  │                                           │  │  │  │                             │  │
│  │  ┌───────────────┐   ┌──────────────────┐ │  │  │  │  ┌────────────────┐        │  │
│  │  │ kubelet       │   │ kube-proxy       │ │  │  │  │  │ containerd     │        │  │
│  │  └───────────────┘   └──────────────────┘ │  │  │  │  └────────────────┘        │  │
│  │                                           │  │  │  │                             │  │
│  └───────────────────────────────────────────┘  │  │  └─────────────────────────────┘  │
│                                                 │  │                                   │
│  ┌─ Container Runtime ───────────────────────┐  │  │  ┌─ System Components ──────────┐  │
│  │                                           │  │  │  │                             │  │
│  │  ┌───────────────┐   ┌──────────────────┐ │  │  │  │  ┌────────────────┐        │  │
│  │  │ containerd    │   │ Flannel (CNI)    │ │  │  │  │  │ kubelet        │        │  │
│  │  └───────────────┘   └──────────────────┘ │  │  │  │  └────────────────┘        │  │
│  │                                           │  │  │  │                             │  │
│  └───────────────────────────────────────────┘  │  │  │  ┌────────────────┐        │  │
│                                                 │  │  │  │ Flannel (CNI)  │        │  │
└─────────────────────────────────────────────────┘  │  │  └────────────────┘        │  │
                                                     │  │                             │  │
                                                     │  └─────────────────────────────┘  │
                                                     │                                   │
                                                     └───────────────────────────────────┘
```

## 5. Setup Process in Detail

### 5.1 Infrastructure Provisioning (Terraform)

1. **VPC and Networking**:
   - Creates VPC, subnet, internet gateway, and route tables
   - Sets up security groups for node communication
   - Provisions a Network Load Balancer for the API server

2. **Auto Scaling Groups**:
   - Creates separate ASGs for control plane and worker nodes
   - Enables auto-healing: if a node fails, it's automatically replaced
   - Uses launch templates with user-data scripts for initialization

### 5.2 Control Plane Node Setup

**Installation Steps**:
1. Install containerd as the container runtime
2. Set up CNI plugins for networking
3. Download Kubernetes components (kubelet, kubeadm, kubectl)
4. Configure the kubelet systemd service
5. Prepare for kubeadm initialization

**Initialization Process (First Control Plane)**:
1. The node with index 1 initializes the cluster:
   ```bash
   kubeadm init --control-plane-endpoint="<load-balancer-dns>:6443" \
     --upload-certs \
     --pod-network-cidr=10.244.0.0/16
   ```
2. This process:
   - Generates cluster certificates in `/etc/kubernetes/pki/`
   - Creates kubelet configuration
   - Starts control plane components as static pods in `/etc/kubernetes/manifests/`
   - Generates a token and certificate key for other nodes to join
   - Creates the `/etc/kubernetes/admin.conf` file

3. The Flannel CNI is installed:
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
   ```

**Additional Control Plane Nodes**:
1. Get the join command from the first control plane
2. Join with the control-plane flag:
   ```bash
   kubeadm join <lb-dns>:6443 --control-plane --certificate-key <key>
   ```
3. This sets up additional instances of kube-apiserver, kube-controller-manager, kube-scheduler, and connects to the same etcd cluster

### 5.3 Worker Node Setup

**Installation Steps**:
1. Same container runtime (containerd) and CNI plugins as control plane
2. Download kubeadm and kubelet (kubectl not required)
3. Configure the kubelet systemd service

**Join Process**:
1. Wait for control plane API to be accessible
2. Get the join command from a control plane node
3. Join the cluster:
   ```bash
   kubeadm join <lb-dns>:6443 --token <token> --discovery-token-ca-cert-hash <hash>
   ```
4. This configures the kubelet to connect to the API server
5. Node becomes available for workload scheduling

### 5.4 High Availability Design

- **Control Plane Redundancy**: Multiple control plane nodes run the same components
- **Load Balancer**: Routes API requests to any available control plane node
- **Auto Scaling Groups**: Automatically replace failed nodes
- **etcd Cluster**: Distributed across all control plane nodes
- **Static IP Address**: Elastic IP for consistent access to services even after cluster rebuild

### 5.5 Networking

- **Pod Network CIDR**: 10.244.0.0/16 (Flannel default)
- **Service CIDR**: 10.96.0.0/12 (Kubernetes default)
- **Node-to-Node Communication**: Enabled through Security Group rules
- **External Access**: Load Balancer for API, can be extended with Ingress for services

## 6. Maintenance Operations

### 6.1 Sleep/Wake Functionality

The cluster includes scripts to scale down to zero nodes when not in use (sleep) and scale back up when needed (wake), saving costs while preserving all configurations. The implementation:

- Scales EC2 instances down to zero
- Removes the Network Load Balancer to avoid hourly costs
- Preserves the Elastic IP allocation for consistent addressing
- Re-attaches the same Elastic IP when the cluster wakes up

### 6.2 IP Address Persistence

- **Elastic IP Strategy**:
  - Configured with `prevent_destroy = true` in Terraform
  - Persists across cluster destroy/create cycles
  - Ensures services maintain the same public IP address
  - Simplifies DNS configuration and external access
  - Costs only $0.005/hour (~$3.60/month) when not attached to a running instance

### 6.2 Accessing the Cluster

After initialization, the kubeconfig is retrieved from a control plane node and configured to use the load balancer endpoint.

## 7. Installation Components

Below is a detailed list of all software components installed on the nodes:

**Control Plane Nodes**:
- containerd (container runtime)
- CNI plugins (container networking)
- crictl (container runtime interface CLI)
- kubelet (node agent)
- kubeadm (cluster bootstrap tool)
- kubectl (cluster CLI)

**Worker Nodes**:
- containerd (container runtime)
- CNI plugins (container networking)
- crictl (container runtime interface CLI)
- kubelet (node agent)
- kubeadm (cluster bootstrap tool)

## 8. File Locations

- **Kubernetes configs**: `/etc/kubernetes/`
- **Certificates**: `/etc/kubernetes/pki/`
- **Kubelet config**: `/var/lib/kubelet/config.yaml`
- **Static pod manifests**: `/etc/kubernetes/manifests/`
- **Kubeconfig**: `/etc/kubernetes/admin.conf` (on nodes), `~/.kube/config` (on admin workstation)

## 9. Implementation Details

### 9.1 Node Identity and Uniqueness

- **Unique Hostname Generation**: 
  - Each node generates a unique hostname using its EC2 instance ID
  - Example: `k8s-control-plane-0390d414` where `0390d414` is part of the EC2 instance ID
  - This prevents hostname conflicts in auto-scaling environments

- **IMDSv2 Token-based Authentication**:
  - Secure access to EC2 instance metadata service
  - Uses token-based authentication instead of IMDSv1
  - More secure against SSRF (Server Side Request Forgery) attacks

### 9.2 Node-to-Node Communication

- **SSH Key Distribution**:
  - Each node has both public and private keys
  - Public key in authorized_keys for incoming connections
  - Private key for outgoing connections to other nodes
  - SSH config to disable host checking for internal VPC IPs

### 9.3 High Availability Control Plane

- **Primary Control Plane Selection**:
  - Deterministic primary selection using IP address sorting
  - First node (lowest IP address) initializes the cluster
  - Additional control plane nodes join the existing cluster

- **Certificate Distribution**:
  - First control plane node uploads certificates to be shared
  - Additional control plane nodes download certificates during join

### 9.4 Worker Node Joining Logic

- **Multi-stage Join Process**:
  - Node waits for control plane API to be accessible
  - Tries to get join command directly from control plane nodes
  - Falls back to generating join command if needed
  - Resets any previous Kubernetes state before joining

### 9.5 Persistence and Recovery

- **Auto Scaling Groups**:
  - Maintain desired capacity of nodes
  - Replace unhealthy instances automatically
  - Use launch templates with initialization scripts

- **User Data Scripts**:
  - Handle initial node setup and cluster joining
  - Ensure idempotent operations for reliability
  - Clean up residual files before joining to prevent conflicts

## 10. Monitoring and Dashboard

### 10.1 Kubernetes Dashboard

- Web-based UI for managing Kubernetes cluster
- Provides visual representation of cluster resources
- Secured with RBAC and token-based authentication
- Features include:
  - Resource monitoring and management
  - Container logs viewing
  - Deployment management
  - Troubleshooting capabilities

### 10.2 Prometheus Monitoring

- Time-series database for metrics collection
- Components:
  - **Prometheus Server**: Core component that scrapes and stores metrics
  - **Alert Manager**: Handles alerts and notifications
  - **Exporters**: Expose metrics from various systems
  - **Push Gateway**: Allows ephemeral jobs to expose metrics

### 10.3 Grafana

- Visualization platform for monitoring data
- Connects to Prometheus as a data source
- Provides pre-configured dashboards for Kubernetes monitoring:
  - Node metrics (CPU, memory, disk, network)
  - Pod and container metrics
  - Control plane health
  - Cluster-wide resource utilization
  
### 10.4 Installation Process

The monitoring stack is installed after the Kubernetes cluster is fully operational:

1. **Dashboard**: 
   - Deployed as a set of Kubernetes resources
   - Creates admin service account with appropriate RBAC permissions
   - Generates secure access token

2. **Prometheus & Grafana**:
   - Installed via Helm charts (kube-prometheus-stack)
   - Set up in dedicated 'monitoring' namespace
   - Automatically discovers and scrapes Kubernetes components

### 10.5 Access Methods

- **Kubernetes Dashboard**: 
  - Accessed via kubectl proxy at:
    `http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/`
  - Requires token authentication

- **Grafana**: 
  - Accessed via port-forwarding:
    `kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80`
  - Default credentials: admin/admin

- **Prometheus**: 
  - Accessed via port-forwarding:
    `kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090`

## 11. Cost Analysis and Optimization

### 11.1 Cost Components

| Component | Type | Cost (USD) | Notes |
|-----------|------|------------|-------|
| Control Plane | On-demand | ~$60/month | 2 x t3.medium nodes, 24/7 operation |
| Worker Nodes | Spot | ~$114/month | 2 x g4dn.xlarge nodes, 70% spot discount |
| Network Load Balancer | - | ~$16.43/month | Basic charge |
| Elastic IP | - | $0 or $3.60/month | Free when attached, $3.60 when idle |
| EBS Storage | gp3 | ~$30/month | 100GB per node, 4 nodes |
| Data Transfer | - | Variable | First 1GB free, then $0.09/GB |
| **Total** | - | **~$220/month** | Full usage without sleep/wake |

### 11.2 Cost Optimization Strategies

- **Sleep/Wake Functionality**:
  - Scales instances to 0 when not in use
  - Removes Network Load Balancer during sleep
  - Preserves Elastic IP allocation
  - Potential savings: ~$200/month if sleeping 80% of the time
  
- **Spot Instance Usage**:
  - Worker nodes use spot instances for up to 70% cost reduction
  - Fall back to on-demand only if spot availability is limited
  
- **Resource Right-sizing**:
  - Control plane: t3.medium provides sufficient resources for low-traffic clusters
  - Worker nodes: g4dn.xlarge balances GPU capability with cost
  
- **Storage Optimization**:
  - gp3 volumes for better price/performance ratio
  - Ephemeral storage used where possible
  
- **Network Cost Management**:
  - Cluster traffic stays in the same AWS region to minimize transfer costs
  - Elastic IP reduces DNS and reconfiguration overhead

### 11.3 Cost Monitoring and Governance

- **Tracking**:
  - AWS Cost Explorer for detailed usage analysis
  - AWS Budgets for threshold alerts
  
- **Tagging Strategy**:
  - All resources tagged for cost allocation
  - Separate tags for cluster components, monitoring, and applications
  
- **Automated Cost Controls**:
  - Sleep/wake scripts to enforce cost discipline
  - Resource quotas to prevent overprovisioning
  - Horizontal Pod Autoscaler to efficiently use resources