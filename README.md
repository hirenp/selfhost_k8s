# My Self-Hosted Kubernetes Cluster on AWS

This is my personal project to set up a self-hosted Kubernetes cluster on AWS EC2 instances using Terraform.

## Key Features

- Auto-healing: Uses AWS Auto Scaling Groups to automatically replace failed nodes
- High availability: 2 control plane nodes with Network Load Balancer
- Scalable: 3 worker nodes that can be easily scaled up or down

## Architecture

- 2 control plane nodes for high availability
- 3 worker nodes 
- Network Load Balancer for the Kubernetes API
- VPC with a public subnet
- Security groups for cluster communication

## Prerequisites

- AWS CLI configured with my account credentials
- Terraform installed
- SSH key pair for accessing the EC2 instances
- kubectl for interacting with the Kubernetes cluster

## Deployment Steps

1. Initialize Terraform:

```bash
cd terraform
terraform init
```

2. Before applying, check `variables.tf` to adjust:
   - Instance types
   - AWS region
   - AMI ID
   - SSH key path

3. Deploy the infrastructure:

```bash
terraform apply
```

4. After deployment completes, set up kubeconfig:

```bash
cd ../scripts
./setup_kubeconfig.sh
```

5. Verify the cluster is running:

```bash
kubectl get nodes
```

## Components Used

- **Terraform**: AWS infrastructure provisioning
- **kubeadm**: Kubernetes cluster bootstrapping
- **containerd**: Container runtime
- **Flannel**: Network plugin

## Cleanup

To tear down the infrastructure:

```bash
cd terraform
terraform destroy
```

## Troubleshooting Notes

If nodes fail to join the cluster:

1. SSH into the control plane:
```bash
ssh -i ~/.ssh/id_rsa ubuntu@<control-plane-ip>
```

2. Check initialization status:
```bash
cat /tmp/kubeadm-init.log
```

3. Check join command:
```bash
cat /tmp/kubeadm-join-command.sh
```