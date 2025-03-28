provider "aws" {
  region = var.aws_region
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

  # Allow all traffic within the security group
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
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
  key_name   = "k8s-key-pair"
  public_key = file(var.public_key_path)
}

# Launch template for control plane nodes
resource "aws_launch_template" "control_plane" {
  name_prefix   = "k8s-control-plane-"
  image_id      = var.ami_id
  instance_type = var.control_plane_instance_type
  key_name      = aws_key_pair.k8s_key_pair.key_name
  
  vpc_security_group_ids = [aws_security_group.k8s_sg.id]

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

  user_data = base64encode(templatefile("${path.module}/scripts/control_plane_init.sh.tpl", {
    node_index = "ASG-PLACEHOLDER" # Will be replaced in each instance
  }))
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
      Role = "worker"
    }
  }

  user_data = base64encode(templatefile("${path.module}/scripts/worker_init.sh.tpl", {
    node_index = "ASG-PLACEHOLDER" # Will be replaced in each instance
  }))
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