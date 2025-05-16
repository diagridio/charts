module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0" # Use the official AWS VPC module
  name    = "${var.cluster_name}-vpc"
  cidr    = var.vpc_cidr
  azs     = [format("%sa", var.aws_region), format("%sb", var.aws_region), format("%sc", var.aws_region)]

  # Only private subnets for cluster resources
  private_subnets = [
    "10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"
  ]

  # Create NAT Gateway in each AZ for outbound access (no direct IGW route for instances)
  public_subnets         = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"] # Subnets to host NAT gateways
  enable_nat_gateway     = true
  one_nat_gateway_per_az = true
  single_nat_gateway     = false

  # Add required tags for AWS Load Balancer Controller
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  tags = {
    "Name" = "${var.cluster_name}-vpc"
  }
}
