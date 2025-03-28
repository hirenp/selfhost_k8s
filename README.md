# Self-Hosted Kubernetes on AWS

This project sets up a self-hosted Kubernetes cluster on AWS using Terraform and basic EC2 instances. The goal is to create a production-grade Kubernetes cluster without using EKS.

## Architecture

The cluster consists of:
- 2 control plane nodes for high availability
- 3 worker nodes
- Network Load Balancer for the Kubernetes API
- Auto Scaling Groups for node management

See the [ARCHITECTURE.md](ARCHITECTURE.md) file for more details.

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform installed (v1.0.0+)
- SSH key pair for accessing the instances
- `kubectl` installed locally

## Setup

1. Clone this repository
2. Generate an SSH key pair:
```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa_aws -N ""
```

3. Initialize Terraform:
```bash
cd terraform
terraform init
```

4. Apply the Terraform configuration:
```bash
terraform apply
```

5. After the cluster is created, set up your kubeconfig:
```bash
cd ../scripts
./setup_kubeconfig.sh
```

6. Test that you can access the cluster:
```bash
kubectl get nodes
```

## Cluster Management

### Sleep/Wake functionality

To save on costs, you can "sleep" the cluster by scaling the EC2 instances to 0, and "wake" it up later:

```bash
./scripts/manage_cluster.sh sleep
./scripts/manage_cluster.sh wake
```

### Accessing the Kubernetes Dashboard

To access the Kubernetes dashboard:

```bash
./scripts/access_dashboard.sh
```

## Troubleshooting

### Node Issues

If one of the nodes is having issues:

1. Check if the node is running in the AWS console
2. SSH into the node:
   ```bash
   ssh -i ~/.ssh/id_rsa_aws ubuntu@<node-public-ip>
   ```
3. Check logs:
   ```bash
   sudo journalctl -u kubelet
   ```

### Certificate Issues

If you see certificate verification errors:
   
1. Re-run the setup_kubeconfig.sh script
2. Check that the correct CA certificate is being used

### Networking Issues

If pods can't communicate across nodes:

1. Check Flannel status:
   ```bash
   kubectl -n kube-system get pods | grep flannel
   ```
2. Look at CNI configuration:
   ```bash
   ssh -i ~/.ssh/id_rsa_aws ubuntu@<node-public-ip> "sudo ls -la /etc/cni/net.d/"
   ```

## Recent Improvements

The following improvements have been made to ensure reliable cluster operation:

1. **Fixed hostname uniqueness issues:**
   - Now using EC2 instance IDs in hostnames for guaranteed uniqueness
   - Proper IMDSv2 token-based authentication for metadata access
   - Hostnames are explicitly passed to kubelet and kubeadm

2. **Improved SSH connectivity between nodes:**
   - Added the private key to all nodes for outgoing connections
   - SSH config to disable host checking for internal IPs
   - Better file permissions for key files

3. **Enhanced node discovery and joining:**
   - IP-based sorting to deterministically identify the primary control plane 
   - Multiple fallback mechanisms for fetching join commands
   - More resilient to networking issues between nodes

4. **Better error handling and diagnostics:**
   - Added more verbosity to critical operations
   - Improved logging of node hostnames and IPs
   - More robust checking of join command success

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.