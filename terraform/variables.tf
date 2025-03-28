variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-1"
}


variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "ami_id" {
  description = "AMI ID for EC2 instances (Ubuntu 20.04 LTS)"
  type        = string
  default     = "ami-04f7a54071e74f488" # Ubuntu Server 24.04 LTS (HVM), SSD Volume Type
}

variable "control_plane_instance_type" {
  description = "Instance type for control plane nodes"
  type        = string
  default     = "t3.medium" # Minimum 2 vCPU, 4GB RAM for control plane
}

variable "worker_instance_type" {
  description = "Instance type for worker nodes"
  type        = string
  default     = "t3.small" # Recommended 2 vCPU, 2GB RAM for workers
}

variable "control_plane_count" {
  description = "Number of control plane nodes"
  type        = number
  default     = 2 # ideally we should have 3
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 3
}

variable "public_key_path" {
  description = "Path to public key for SSH access"
  type        = string
  default     = "~/.ssh/id_rsa_aws.pub"
}

variable "private_key_path" {
  description = "Path to private key for node-to-node communication"
  type        = string
  default     = "~/.ssh/id_rsa_aws"
}

variable "key_name" {
  description = "Name of the AWS key pair"
  type        = string
  default     = "k8s-key"
}
