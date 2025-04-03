provider "aws" {
  region = var.aws_region
}

# IAM role for EC2 instances
resource "aws_iam_role" "k8s_node_role" {
  name_prefix = "k8s-node-role-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
  
  lifecycle {
    create_before_destroy = true
  }
}

# IAM policy for EC2 instances to access AWS resources
resource "aws_iam_policy" "k8s_node_policy" {
  name_prefix = "k8s-node-policy-"
  description = "Policy allowing K8s nodes to access AWS resources"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeTags",
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
  
  lifecycle {
    create_before_destroy = true
  }
}

# Attach the policy to the role
resource "aws_iam_role_policy_attachment" "k8s_node_policy_attachment" {
  role       = aws_iam_role.k8s_node_role.name
  policy_arn = aws_iam_policy.k8s_node_policy.arn
}

# Create an instance profile
resource "aws_iam_instance_profile" "k8s_node_profile" {
  name_prefix = "k8s-node-profile-"
  role        = aws_iam_role.k8s_node_role.name
  
  lifecycle {
    create_before_destroy = true
  }
}

# VPC for Kubernetes cluster
resource "aws_vpc" "k8s_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "k8s-vpc"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "k8s_igw" {
  vpc_id = aws_vpc.k8s_vpc.id

  tags = {
    Name = "k8s-igw"
  }
}

# Public Subnet
resource "aws_subnet" "k8s_public_subnet" {
  vpc_id                  = aws_vpc.k8s_vpc.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"

  tags = {
    Name = "k8s-public-subnet"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "kubernetes.io/role/elb" = "1"
  }
}

# Additional Public Subnet for Load Balancer redundancy
resource "aws_subnet" "k8s_public_subnet_2" {
  vpc_id                  = aws_vpc.k8s_vpc.id
  cidr_block              = var.public_subnet_cidr_2
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}c"

  tags = {
    Name = "k8s-public-subnet-2"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "kubernetes.io/role/elb" = "1"
  }
}

# Route Table
resource "aws_route_table" "k8s_public_rt" {
  vpc_id = aws_vpc.k8s_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.k8s_igw.id
  }

  tags = {
    Name = "k8s-public-rt"
  }
}

# Route Table Association
resource "aws_route_table_association" "k8s_public_rta" {
  subnet_id      = aws_subnet.k8s_public_subnet.id
  route_table_id = aws_route_table.k8s_public_rt.id
}

resource "aws_route_table_association" "k8s_public_rta_2" {
  subnet_id      = aws_subnet.k8s_public_subnet_2.id
  route_table_id = aws_route_table.k8s_public_rt.id
}

# Private Subnet for Worker Nodes
resource "aws_subnet" "k8s_private_subnet" {
  vpc_id                  = aws_vpc.k8s_vpc.id
  cidr_block              = var.private_subnet_cidr
  map_public_ip_on_launch = false
  availability_zone       = "${var.aws_region}a"
  
  tags = {
    Name = "k8s-private-subnet"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# Additional Private Subnet for Load Balancer redundancy
resource "aws_subnet" "k8s_private_subnet_2" {
  vpc_id                  = aws_vpc.k8s_vpc.id
  cidr_block              = var.private_subnet_cidr_2
  map_public_ip_on_launch = false
  availability_zone       = "${var.aws_region}c"
  
  tags = {
    Name = "k8s-private-subnet-2"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# Private Route Table
resource "aws_route_table" "k8s_private_rt" {
  vpc_id = aws_vpc.k8s_vpc.id
  
  # Route through internet gateway instead of NAT gateway
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.k8s_igw.id
  }
  
  tags = {
    Name = "k8s-private-rt"
  }
}

# Private Route Table Association
resource "aws_route_table_association" "k8s_private_rta" {
  subnet_id      = aws_subnet.k8s_private_subnet.id
  route_table_id = aws_route_table.k8s_private_rt.id
}

resource "aws_route_table_association" "k8s_private_rta_2" {
  subnet_id      = aws_subnet.k8s_private_subnet_2.id
  route_table_id = aws_route_table.k8s_private_rt.id
}

# Security Group for Kubernetes
resource "aws_security_group" "k8s_sg" {
  name        = "k8s-sg"
  description = "Security group for Kubernetes cluster"
  vpc_id      = aws_vpc.k8s_vpc.id

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Kubernetes API
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP"
  }

  # HTTPS
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTPS"
  }

  # NodePort HTTP
  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow Kubernetes NodePort range"
  }

  # Allow all traffic within the security group
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }
  
  # Allow all internal traffic within the VPC
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "k8s-sg"
  }
}

# Key Pair
resource "aws_key_pair" "k8s_key_pair" {
  key_name   = var.key_name
  public_key = file(var.public_key_path)
}

# Launch template for control plane nodes
resource "aws_launch_template" "control_plane" {
  name_prefix   = "k8s-control-plane-"
  image_id      = var.ami_id
  instance_type = var.control_plane_instance_type
  key_name      = aws_key_pair.k8s_key_pair.key_name
  
  vpc_security_group_ids = [aws_security_group.k8s_sg.id]
  
  iam_instance_profile {
    name = aws_iam_instance_profile.k8s_node_profile.name
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    
    ebs {
      volume_size = 50
      volume_type = "gp3"
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    
    tags = {
      Role = "control-plane"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    }
  }

  user_data = base64encode(
    replace(
      replace(
        replace(
          replace(
            file("${path.module}/user_data_control_plane.sh"),
            "SSH_KEY_PLACEHOLDER", file(var.public_key_path)
          ),
          "PRIVATE_KEY_PLACEHOLDER", file(var.private_key_path)
        ),
        "LOAD_BALANCER_DNS_PLACEHOLDER", aws_lb.k8s_api_lb.dns_name
      ),
      "AWS_REGION_PLACEHOLDER", var.aws_region
    )
  )
}

# Auto Scaling Group for control plane nodes
resource "aws_autoscaling_group" "control_plane" {
  name                = "k8s-control-plane-asg"
  desired_capacity    = var.control_plane_count
  min_size            = var.control_plane_count
  max_size            = var.control_plane_count + 1
  vpc_zone_identifier = [aws_subnet.k8s_public_subnet.id, aws_subnet.k8s_public_subnet_2.id]
  health_check_type   = "EC2"
  health_check_grace_period = 300
  force_delete        = true
  
  # Special settings for Kubernetes control plane
  termination_policies = ["OldestInstance"]
  default_instance_warmup = 300

  # Use the launch template
  launch_template {
    id      = aws_launch_template.control_plane.id
    version = "$Latest"
  }

  # Set unique names for each instance
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "k8s-control-plane"
    propagate_at_launch = true
  }
  
  tag {
    key                 = "kubernetes.io/cluster/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }
}

# Launch template for worker nodes
resource "aws_launch_template" "worker" {
  name_prefix   = "k8s-worker-"
  image_id      = var.ami_id
  instance_type = var.worker_instance_type
  key_name      = aws_key_pair.k8s_key_pair.key_name
  
  vpc_security_group_ids = [aws_security_group.k8s_sg.id]
  
  iam_instance_profile {
    name = aws_iam_instance_profile.k8s_node_profile.name
  }

  # Configure spot instances if enabled
  dynamic "instance_market_options" {
    for_each = var.use_spot_instances ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        max_price = var.spot_price
        instance_interruption_behavior = "terminate"
      }
    }
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    
    ebs {
      volume_size = 100  # Increased for GPU workloads
      volume_type = "gp3"
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    
    tags = {
      Role = "worker"
      GPU = "true"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    }
  }
  
  # Additional tags for the ASG to propagate to instances
  tag_specifications {
    resource_type = "volume"
    
    tags = {
      Role = "worker"
    }
  }

  user_data = base64encode(
    replace(
      replace(
        replace(
          replace(
            file("${path.module}/user_data_worker.sh"),
            "SSH_KEY_PLACEHOLDER", file(var.public_key_path)
          ),
          "PRIVATE_KEY_PLACEHOLDER", file(var.private_key_path)
        ),
        "LOAD_BALANCER_DNS_PLACEHOLDER", aws_lb.k8s_api_lb.dns_name
      ),
      "AWS_REGION_PLACEHOLDER", var.aws_region
    )
  )
}

# Auto Scaling Group for worker nodes
resource "aws_autoscaling_group" "worker" {
  name                = "k8s-worker-asg"
  desired_capacity    = var.worker_count
  min_size            = var.worker_count
  max_size            = var.worker_count + 2
  vpc_zone_identifier = [aws_subnet.k8s_public_subnet.id, aws_subnet.k8s_public_subnet_2.id]
  health_check_type   = "EC2"
  health_check_grace_period = 300
  force_delete        = true
  
  # Special settings for Kubernetes workers
  termination_policies = ["OldestInstance"]
  default_instance_warmup = 300

  # Use the launch template
  launch_template {
    id      = aws_launch_template.worker.id
    version = "$Latest"
  }

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "k8s-worker"
    propagate_at_launch = true
  }
  
  tag {
    key                 = "GPU"
    value               = "true"
    propagate_at_launch = true
  }
  
  tag {
    key                 = "kubernetes.io/cluster/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }
}

# Load Balancer for the control plane API
resource "aws_lb" "k8s_api_lb" {
  name               = "k8s-api-lb"
  internal           = false
  load_balancer_type = "network"
  subnets            = [aws_subnet.k8s_public_subnet.id, aws_subnet.k8s_public_subnet_2.id]

  tags = {
    Name = "k8s-api-lb"
  }
}

resource "aws_lb_target_group" "k8s_api_tg" {
  name     = "k8s-api-tg"
  port     = 6443
  protocol = "TCP"
  vpc_id   = aws_vpc.k8s_vpc.id

  health_check {
    protocol = "TCP"
    port     = 6443
  }
}

resource "aws_autoscaling_attachment" "k8s_api_tg_attachment" {
  autoscaling_group_name = aws_autoscaling_group.control_plane.name
  lb_target_group_arn    = aws_lb_target_group.k8s_api_tg.arn
}

resource "aws_lb_listener" "k8s_api_listener" {
  load_balancer_arn = aws_lb.k8s_api_lb.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.k8s_api_tg.arn
  }
}

# Load Balancer Controller IAM Module
module "aws_load_balancer_controller" {
  source = "./modules/lb-controller"
  
  region       = var.aws_region
  cluster_name = var.cluster_name
}

# Security group for AWS Load Balancer Controller backend traffic
resource "aws_security_group" "lb_controller_backend" {
  name        = "k8s-traffic-lb-controller-backend"
  description = "Security group for AWS Load Balancer Controller backend traffic"
  vpc_id      = aws_vpc.k8s_vpc.id

  # Allow NodePort range for Kubernetes services
  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow traffic to NodePort range for Load Balancer Controller"
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Tag required for AWS Load Balancer Controller
  tags = {
    Name                     = "lb-controller-backend-sg"
    "elbv2.k8s.aws/cluster" = var.cluster_name
  }
}

# Output LB DNS name
output "k8s_api_lb_dns" {
  value = aws_lb.k8s_api_lb.dns_name
  description = "DNS name of the load balancer for the Kubernetes API"
}

# Output the Auto Scaling Group names
output "control_plane_asg_name" {
  value = aws_autoscaling_group.control_plane.name
  description = "Name of the Auto Scaling Group for control plane nodes"
}

output "worker_asg_name" {
  value = aws_autoscaling_group.worker.name
  description = "Name of the Auto Scaling Group for worker nodes"
}

# Output the AWS region
output "aws_region" {
  value = var.aws_region
  description = "AWS region where the cluster is deployed"
}

# Output the LB Controller role ARN
output "aws_load_balancer_controller_role_arn" {
  value = module.aws_load_balancer_controller.aws_load_balancer_controller_role_arn
  description = "ARN of the IAM role for the AWS Load Balancer Controller"
}

# Output cluster name
output "cluster_name" {
  value = var.cluster_name
  description = "Name of the Kubernetes cluster"
}

# Output VPC ID for use by the AWS Load Balancer Controller
output "vpc_id" {
  value = aws_vpc.k8s_vpc.id
  description = "ID of the VPC where the cluster is deployed"
}

# Output Load Balancer Controller backend security group ID
output "lb_controller_backend_sg_id" {
  value = aws_security_group.lb_controller_backend.id
  description = "ID of the security group to be used by the AWS Load Balancer Controller for backend traffic"
}