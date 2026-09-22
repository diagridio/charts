terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.97"
    }
  }
}

# One provider per member region, because this stack reads a load balancer in
# each of them unless it is given the ARN, and a third for the global services.
#
# The two member providers skip the checks the AWS provider otherwise makes
# when it is configured. Terraform configures a provider even when the only
# thing using it has no instances, so with primary_gateway_lb_arn given the
# provider below would still have called GetCallerIdentity against that
# region's STS endpoint — reintroducing the dependency on a reachable region
# that giving the ARN exists to remove. Bad credentials now surface on the
# Load Balancer lookup instead of before it, which only affects the path that
# was going to call that region anyway.
provider "aws" {
  alias  = "primary"
  region = var.primary_aws_region

  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_region_validation      = true

  default_tags {
    tags = var.tags
  }
}

provider "aws" {
  alias  = "secondary"
  region = var.secondary_aws_region

  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_region_validation      = true

  default_tags {
    tags = var.tags
  }
}

# Global Accelerator's control plane lives in us-west-2 whatever the endpoints
# are, and Route 53 is global. Both go through this provider.
provider "aws" {
  alias  = "global"
  region = "us-west-2"

  default_tags {
    tags = var.tags
  }
}
