resource "aws_iam_role_policy_attachments_exclusive" "cluster" {
  role_name = module.eks.eks_managed_node_groups["workers"].iam_role_name
  policy_arns = [
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSComputePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSServicePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
  ]
}

# Create a custom policy for certmanager Route53 permissions
resource "aws_iam_policy" "certmanager_route53_policy" {
  name        = "${var.cluster_name}-${var.aws_region}-certmanager-route53-policy"
  description = "Policy for certmanager to modify and check Route53 hostedzones"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:aws:route53:::change/*"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets"
        ]
        Resource = "arn:aws:route53:::hostedzone/*"
      },
      {
        Effect   = "Allow"
        Action   = "route53:ListHostedZonesByName"
        Resource = "*"
      }
    ]
  })
}

# Create IAM role for cert-manager service account with OIDC federation
resource "aws_iam_role" "cert_manager_role" {
  name = "${var.cluster_name}-${var.aws_region}-cert-manager-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com",
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:cert-manager:cert-manager"
          },
        }
      }
    ]
  })
}

# Attach the certmanager Route53 policy to the cert-manager role
resource "aws_iam_role_policy_attachment" "cert_manager_route53" {
  role       = aws_iam_role.cert_manager_role.name
  policy_arn = aws_iam_policy.certmanager_route53_policy.arn
}

# EKS Cluster using the terraform-aws-modules/eks/aws module
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  # VPC and subnet configuration
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Cluster access configuration
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = false

  # Allow access from bastion host
  cluster_security_group_additional_rules = {
    bastion_https_access = {
      description              = "Allow HTTPS access from bastion host"
      protocol                 = "tcp"
      from_port                = 443
      to_port                  = 443
      source_security_group_id = var.enable_bastion ? aws_security_group.bastion_sg[0].id : null
      type                     = "ingress"
    }
  }

  # Node groups configuration
  eks_managed_node_groups = {
    workers = {
      subnet_ids = module.vpc.private_subnets

      min_size     = var.node_min_capacity
      max_size     = var.node_max_capacity
      desired_size = var.node_desired_capacity

      instance_types = [var.node_instance_type]
    }
  }

  # Enable EKS addons
  cluster_addons = {
    aws-ebs-csi-driver = {
      most_recent = true
      version     = var.ebs_csi_addon_version
    }
    coredns = {
      most_recent = true
      version     = var.coredns_addon_version
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  # Enable OIDC provider for service accounts
  enable_irsa = true
}

# TLS needed for the thumbprint
provider "tls" {}

# Access entry for the bastion host IAM role (if enabled)
resource "aws_eks_access_entry" "bastion_role" {
  count         = var.enable_bastion ? 1 : 0
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.bastion_role[0].arn
  type          = "STANDARD"
}

# Access entries for admin IAM roles
resource "aws_eks_access_entry" "admin_roles" {
  for_each      = toset(var.eks_admin_roles)
  cluster_name  = module.eks.cluster_name
  principal_arn = each.value
  type          = "STANDARD"
}

# Access entries for admin IAM users
resource "aws_eks_access_entry" "admin_users" {
  for_each      = toset(var.eks_admin_users)
  cluster_name  = module.eks.cluster_name
  principal_arn = each.value
  type          = "STANDARD"
}

# Access entries for read-only IAM roles
resource "aws_eks_access_entry" "readonly_roles" {
  for_each      = toset(var.eks_readonly_roles)
  cluster_name  = module.eks.cluster_name
  principal_arn = each.value
  type          = "STANDARD"
}

# Access entries for read-only IAM users
resource "aws_eks_access_entry" "readonly_users" {
  for_each      = toset(var.eks_readonly_users)
  cluster_name  = module.eks.cluster_name
  principal_arn = each.value
  type          = "STANDARD"
}

# Associate the EKS Viewer access policy with read-only roles
resource "aws_eks_access_policy_association" "readonly_roles_policy" {
  for_each      = toset(var.eks_readonly_roles)
  cluster_name  = module.eks.cluster_name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
  principal_arn = each.value
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.readonly_roles]
}

# Associate the EKS Viewer access policy with read-only users
resource "aws_eks_access_policy_association" "readonly_users_policy" {
  for_each      = toset(var.eks_readonly_users)
  cluster_name  = module.eks.cluster_name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
  principal_arn = each.value
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.readonly_users]
}

# Associate the EKS Cluster Admin access policy with bastion role
resource "aws_eks_access_policy_association" "bastion_role_policy" {
  count         = var.enable_bastion ? 1 : 0
  cluster_name  = module.eks.cluster_name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = aws_iam_role.bastion_role[0].arn
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.bastion_role]
}

# Associate the EKS Admin access policy with admin roles
resource "aws_eks_access_policy_association" "admin_roles_policy" {
  for_each      = toset(var.eks_admin_roles)
  cluster_name  = module.eks.cluster_name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
  principal_arn = each.value
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.admin_roles]
}

# Associate the EKS Admin access policy with admin users
resource "aws_eks_access_policy_association" "admin_users_policy" {
  for_each      = toset(var.eks_admin_users)
  cluster_name  = module.eks.cluster_name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
  principal_arn = each.value
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.admin_users]
}




#
# Create IAM role for AWS Load Balancer Controller service account with OIDC federation
resource "aws_iam_role" "aws_load_balancer_controller_role" {
  name = "${var.cluster_name}-${var.aws_region}-aws-load-balancer-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com",
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          },
        }
      }
    ]
  })
}

# Create a custom policy for AWS Load Balancer Controller
resource "aws_iam_policy" "aws_load_balancer_controller_policy" {
  name        = "${var.cluster_name}-${var.aws_region}-aws-load-balancer-controller-policy"
  description = "Policy for AWS Load Balancer Controller"

  policy = file("${path.module}/policies/aws-load-balancer-controller-policy.json")
}

# Attach the custom AWS Load Balancer Controller policy to the role
resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller_policy" {
  role       = aws_iam_role.aws_load_balancer_controller_role.name
  policy_arn = aws_iam_policy.aws_load_balancer_controller_policy.arn
}

# Output the cert-manager IAM role ARN for reference
output "cert_manager_role_arn" {
  description = "ARN of the IAM role for cert-manager service account"
  value       = aws_iam_role.cert_manager_role.arn
}

# Output the AWS Load Balancer Controller IAM role ARN for reference
output "aws_load_balancer_controller_role_arn" {
  description = "ARN of the IAM role for AWS Load Balancer Controller service account"
  value       = aws_iam_role.aws_load_balancer_controller_role.arn
}

# Output the EKS cluster name
output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_id
}