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

# The teardown in the AWS deployment guide checks that the gateway's load
# balancer is gone before destroying anything, and that check filters by VPC:
#
#   aws elbv2 describe-load-balancers --region <region> \
#     --query "LoadBalancers[?VpcId=='<vpc-id>'].LoadBalancerName"
#
# The load balancer and its security groups are created by the AWS Load Balancer
# Controller rather than by Terraform, so there is no resource here to read the
# id off — without this output the reader has to go and find it by hand at the
# one point in the guide where skipping a step leaves a VPC that cannot be
# deleted.
output "vpc_id" {
  description = "ID of this region's VPC. Used by the teardown check for load balancers Terraform does not manage."
  value       = module.vpc.vpc_id
}
