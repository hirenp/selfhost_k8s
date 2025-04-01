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

  tags = {
    Name = "k8s-public-subnet"
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
      volume_type = "gp2"
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    
    tags = {
      Role = "control-plane"
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
  vpc_zone_identifier = [aws_subnet.k8s_public_subnet.id]
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
  vpc_zone_identifier = [aws_subnet.k8s_public_subnet.id]
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
}

# Load Balancer for the control plane API
resource "aws_lb" "k8s_api_lb" {
  name               = "k8s-api-lb"
  internal           = false
  load_balancer_type = "network"
  subnets            = [aws_subnet.k8s_public_subnet.id]

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

# Create an Elastic IP for the ingress controller
resource "aws_eip" "ingress_eip" {
  domain = "vpc"
  tags = {
    Name = "k8s-ingress-eip"
    ManagedBy = "terraform"
  }
  # Removed lifecycle block to allow EIP to be destroyed and recreated
}

# Automatically associate the Elastic IP with a worker node
resource "aws_eip_association" "ingress_eip_assoc" {
  depends_on = [aws_autoscaling_group.worker]
  allocation_id = aws_eip.ingress_eip.id
  # Get the instance ID of the first worker node
  instance_id = data.aws_instances.worker_instances.ids[0]
}

# Data source to get worker node instances
data "aws_instances" "worker_instances" {
  depends_on = [aws_autoscaling_group.worker]
  
  filter {
    name   = "tag:aws:autoscaling:groupName"
    values = [aws_autoscaling_group.worker.name]
  }
  
  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
  
  instance_state_names = ["running"]
}

# Output the AWS region
output "aws_region" {
  value = var.aws_region
  description = "AWS region where the cluster is deployed"
}

# Output the Elastic IP allocation ID and public IP
output "ingress_eip_allocation_id" {
  value = aws_eip.ingress_eip.allocation_id
  description = "Allocation ID of the Elastic IP for the ingress controller"
}

output "ingress_eip_public_ip" {
  value = aws_eip.ingress_eip.public_ip
  description = "Public IP of the Elastic IP for the ingress controller"
}