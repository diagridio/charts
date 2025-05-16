# Bastion Host Configuration
# Only created if enable_bastion is true

# IAM role for bastion host to access EKS cluster
resource "aws_iam_role" "bastion_role" {
  count = var.enable_bastion ? 1 : 0
  name  = "${var.cluster_name}-${var.aws_region}-bastion-role"

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

  tags = {
    Name = "${var.cluster_name}-bastion-role"
  }
}

# Policy to allow bastion to describe EKS cluster
resource "aws_iam_policy" "bastion_eks_policy" {
  count       = var.enable_bastion ? 1 : 0
  name        = "${var.cluster_name}-${var.aws_region}-bastion-eks-policy"
  description = "Policy to allow bastion host to access EKS cluster"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# Attach policy to bastion role
resource "aws_iam_role_policy_attachment" "bastion_eks_policy_attachment" {
  count      = var.enable_bastion ? 1 : 0
  role       = aws_iam_role.bastion_role[0].name
  policy_arn = aws_iam_policy.bastion_eks_policy[0].arn
}

# Attach AmazonEKSClusterPolicy to bastion role
resource "aws_iam_role_policy_attachment" "bastion_eks_cluster_policy" {
  count      = var.enable_bastion ? 1 : 0
  role       = aws_iam_role.bastion_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Create a policy to allow the bastion to use the aws-auth ConfigMap
resource "aws_iam_policy" "bastion_eks_auth_policy" {
  count       = var.enable_bastion ? 1 : 0
  name        = "${var.cluster_name}-${var.aws_region}-bastion-eks-auth-policy"
  description = "Policy to allow bastion host to use the aws-auth ConfigMap"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:AccessKubernetesApi"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# Create a policy to allow EC2 Instance Connect
resource "aws_iam_policy" "ec2_instance_connect_policy" {
  count       = var.enable_bastion ? 1 : 0
  name        = "${var.cluster_name}-${var.aws_region}-ec2-instance-connect-policy"
  description = "Policy to allow EC2 Instance Connect for the bastion host"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ec2-instance-connect:SendSSHPublicKey"
        Resource = "arn:aws:ec2:${var.aws_region}:*:instance/${aws_instance.bastion[0].id}"
        Condition = {
          StringEquals = {
            "aws:PrincipalType" = "User"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_policy" "bastion_ecr_public_policy" {
  count       = var.enable_bastion ? 1 : 0
  name        = "${var.cluster_name}-${var.aws_region}-bastion-ecr-public-policy"
  description = "Policy to allow bastion host to get Public authorization token"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ecr-public:GetAuthorizationToken",
          "sts:GetServiceBearerToken"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# Attach ECR Public policy to bastion role
resource "aws_iam_role_policy_attachment" "bastion_ecr_public_policy_attachment" {
  count      = var.enable_bastion ? 1 : 0
  role       = aws_iam_role.bastion_role[0].name
  policy_arn = aws_iam_policy.bastion_ecr_public_policy[0].arn
}

# Create a policy for EC2 Instance Connect access to the bastion host
resource "aws_iam_policy" "bastion_ec2_instance_connect_access_policy" {
  count       = var.enable_bastion && (length(var.bastion_allowed_iam_users) > 0 || length(var.bastion_allowed_iam_roles) > 0) ? 1 : 0
  name        = "${var.cluster_name}-${var.aws_region}-bastion-ec2-instance-connect-access-policy"
  description = "Policy to allow EC2 Instance Connect access to the bastion host"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ec2-instance-connect:SendSSHPublicKey"
        Resource = "arn:aws:ec2:${var.aws_region}:*:instance/${aws_instance.bastion[0].id}"
      },
      {
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      }
    ]
  })
}

# Attach auth policy to bastion role
resource "aws_iam_role_policy_attachment" "bastion_eks_auth_policy_attachment" {
  count      = var.enable_bastion ? 1 : 0
  role       = aws_iam_role.bastion_role[0].name
  policy_arn = aws_iam_policy.bastion_eks_auth_policy[0].arn
}

# Attach EC2 Instance Connect policy to bastion role
resource "aws_iam_role_policy_attachment" "ec2_instance_connect_policy_attachment" {
  count      = var.enable_bastion ? 1 : 0
  role       = aws_iam_role.bastion_role[0].name
  policy_arn = aws_iam_policy.ec2_instance_connect_policy[0].arn
}

# Create instance profile for bastion host
resource "aws_iam_instance_profile" "bastion_profile" {
  count = var.enable_bastion ? 1 : 0
  name  = "${var.cluster_name}-${var.aws_region}-bastion-profile"
  role  = aws_iam_role.bastion_role[0].name
}

# Generate SSH key pair for bastion host (only if SSH key authentication is enabled)
resource "tls_private_key" "bastion_key" {
  count     = var.enable_bastion && var.enable_bastion_ssh_key ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create AWS key pair from generated key (only if SSH key authentication is enabled)
resource "aws_key_pair" "bastion_key_pair" {
  count      = var.enable_bastion && var.enable_bastion_ssh_key ? 1 : 0
  key_name   = var.bastion_key_name != "" ? var.bastion_key_name : "${var.cluster_name}-bastion-key"
  public_key = var.enable_bastion_ssh_key ? tls_private_key.bastion_key[0].public_key_openssh : ""
}

# Save private key to local file (only if SSH key authentication is enabled)
resource "local_file" "bastion_private_key" {
  count           = var.enable_bastion && var.enable_bastion_ssh_key ? 1 : 0
  content         = tls_private_key.bastion_key[0].private_key_pem
  filename        = "${path.module}/${var.cluster_name}-bastion-key.pem"
  file_permission = "0600"
}

# Security group for the bastion host
resource "aws_security_group" "bastion_sg" {
  count       = var.enable_bastion ? 1 : 0
  name        = "${var.cluster_name}-bastion-sg"
  description = "Security group for bastion host"
  vpc_id      = module.vpc.vpc_id

  # Allow SSH from specified CIDR blocks
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.bastion_allowed_cidr]
    description = "SSH access to bastion host"
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "${var.cluster_name}-bastion-sg"
  }
}

# Get the latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Elastic IP for bastion host
resource "aws_eip" "bastion" {
  count  = var.enable_bastion ? 1 : 0
  domain = "vpc"
  tags = {
    Name = "${var.cluster_name}-bastion-eip"
  }
}


# Bastion host EC2 instance
resource "aws_instance" "bastion" {
  count                       = var.enable_bastion ? 1 : 0
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.bastion_instance_type
  key_name                    = var.enable_bastion_ssh_key ? aws_key_pair.bastion_key_pair[0].key_name : null
  subnet_id                   = module.vpc.public_subnets[0] # Place in first public subnet
  vpc_security_group_ids      = [aws_security_group.bastion_sg[0].id]
  associate_public_ip_address = false # We'll use an Elastic IP instead
  iam_instance_profile        = aws_iam_instance_profile.bastion_profile[0].name

  # Use user_data script from the template file
  user_data = templatefile("${path.module}/scripts/bastion_user_data.sh.tpl", {
    cluster_name = var.cluster_name
    aws_region   = var.aws_region
  })

  tags = {
    Name = "${var.cluster_name}-bastion"
  }

  lifecycle {
    ignore_changes = [associate_public_ip_address]
  }
}

# Associate Elastic IP with bastion host
resource "aws_eip_association" "bastion" {
  count         = var.enable_bastion ? 1 : 0
  instance_id   = aws_instance.bastion[0].id
  allocation_id = aws_eip.bastion[0].id
}

# Output the bastion host public IP
output "bastion_public_ip" {
  description = "Public IP address of the bastion host"
  value       = var.enable_bastion ? aws_eip.bastion[0].public_ip : "Bastion host not enabled"
}

# Output SSH command to connect to bastion using SSH key (only if SSH key authentication is enabled)
output "bastion_ssh_command" {
  description = "SSH command to connect to the bastion host using SSH key"
  value       = var.enable_bastion && var.enable_bastion_ssh_key ? "ssh -i ${var.cluster_name}-bastion-key.pem ec2-user@${aws_eip.bastion[0].public_ip}" : "SSH key authentication not enabled for bastion host"
}

# Output the path to the private key file (only if SSH key authentication is enabled)
output "bastion_private_key_file" {
  description = "Path to the private key file for SSH access to the bastion host"
  value       = var.enable_bastion && var.enable_bastion_ssh_key ? "${path.module}/${var.cluster_name}-bastion-key.pem" : "SSH key authentication not enabled for bastion host"
}

# Output EC2 Instance Connect command to connect to bastion using IAM
output "bastion_ec2_instance_connect_command" {
  description = "Command to connect to the bastion host using EC2 Instance Connect (IAM-based login)"
  value       = var.enable_bastion ? "aws ec2-instance-connect ssh --instance-id ${aws_instance.bastion[0].id} --os-user ec2-user --region ${var.aws_region}" : "Bastion host not enabled"
}