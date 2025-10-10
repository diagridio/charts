# Data source to find NLBs by tags (AWS Load Balancer Controller tags them)
data "aws_lbs" "catalyst_gateway_nlb" {
  tags = {
    "elbv2.k8s.aws/cluster"    = var.cluster_name
    "service.k8s.aws/stack"    = "cra-agent/gateway-envoy"
    "service.k8s.aws/resource" = "LoadBalancer"
  }
}

# Check if NLB exists
locals {
  nlb_arns = tolist(data.aws_lbs.catalyst_gateway_nlb.arns)
  has_nlb  = length(local.nlb_arns) > 0
  nlb_arn  = local.has_nlb ? local.nlb_arns[0] : null
}

data "aws_lb" "catalyst_gateway_nlb" {
  count = local.has_nlb ? 1 : 0
  arn   = local.nlb_arn
}

locals {
  nlb_dns_name = local.has_nlb ? data.aws_lb.catalyst_gateway_nlb[0].dns_name : null
  nlb_zone_id  = local.has_nlb ? data.aws_lb.catalyst_gateway_nlb[0].zone_id : null

  # Create wildcard domain from user input
  wildcard_domain = var.region_ingress_endpoint != null ? "*.${var.region_ingress_endpoint}" : null
  region_ingress_endpoint = local.has_nlb && var.region_ingress_endpoint != null ? "https://*.${var.region_ingress_endpoint}:443" : null
}

resource "aws_route53_zone" "catalyst_hosted_zone" {
  count = local.has_nlb ? 1 : 0

  name = var.region_ingress_endpoint
  tags = {
    Name        = var.cluster_name
  }
}

# Route53 record - only created when NLB exists
resource "aws_route53_record" "catalyst_nlb_wildcard_record" {
  count = local.has_nlb ? 1 : 0
  
  zone_id = aws_route53_zone.catalyst_hosted_zone[0].zone_id
  name    = local.wildcard_domain
  type    = "A"

  alias {
    name                   = local.nlb_dns_name
    zone_id                = local.nlb_zone_id
    evaluate_target_health = true
  }
}

output "region_ingress_endpoint" {
  description = "The ingress endpoint to be used as argument to `diagrid region update` command"
  value       = local.region_ingress_endpoint
}

output "region_wildcard_domain" {
  description = "The region's wildcard domain"
  value       = local.wildcard_domain
}
