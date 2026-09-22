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
  wildcard_domain         = var.region_ingress_endpoint != null ? "*.${var.region_ingress_endpoint}" : null
  region_ingress_endpoint = local.has_nlb && var.region_ingress_endpoint != null ? "https://*.${var.region_ingress_endpoint}:443" : null
}

# Hosted zone - only created when this region is not joining an existing one.
# The second region of a region group passes route53_zone_id so that both
# regions share one wildcard domain.
resource "aws_route53_zone" "catalyst_hosted_zone" {
  count = local.has_nlb && var.route53_zone_id == "" ? 1 : 0

  name = var.region_ingress_endpoint
  tags = {
    Name = var.cluster_name
  }
}

locals {
  zone_id = var.route53_zone_id != "" ? var.route53_zone_id : one(aws_route53_zone.catalyst_hosted_zone[*].zone_id)
}

# The wildcard record for the region's own domain.
#
# A region group has no per-region wildcard record: both regions serve the same
# names, so the name can only resolve to one thing, and that thing is the
# group's front door. The region-group stack owns it. See region-group/.
resource "aws_route53_record" "catalyst_nlb_wildcard_record" {
  count = local.has_nlb && !var.region_group_member ? 1 : 0

  zone_id = local.zone_id
  name    = local.wildcard_domain
  type    = "A"

  alias {
    name                   = local.nlb_dns_name
    zone_id                = local.nlb_zone_id
    evaluate_target_health = true
  }

  # A region given another region's hosted zone is a member of that region's
  # group. Left unmarked it would write the same wildcard name the other region
  # wrote, and the second apply would replace the first region's record.
  lifecycle {
    precondition {
      condition     = var.route53_zone_id == ""
      error_message = "A region joining an existing hosted zone is a region group member: set region_group_member = true, and apply terraform/region-group to point the shared wildcard domain at the group's front door."
    }
  }
}

# This region's own name, bypassing the group's front door.
#
# Only a group member gets one. A standalone region is reached at the wildcard
# above, which already points at its own Load Balancer; a member's wildcard
# points at the group's accelerator, so without this name there is no way to
# reach one named region. Asking a named region whether it accepts writes is
# what every failover check does.
#
# An exact name beats the wildcard in Route 53, and the wildcard certificate
# covers it. It does not evaluate target health: a passive region has to keep
# resolving, because answering 503 there is the whole point of asking it.
#
# It lives here rather than in the region-group stack so that stack needs
# nothing from a member region but its Load Balancer ARN. That is what lets the
# group's front door be re-applied while a member region is unreachable.
resource "aws_route53_record" "catalyst_region_record" {
  count = local.has_nlb && var.region_group_member ? 1 : 0

  zone_id = local.zone_id
  name    = "${var.cluster_name}.${var.region_ingress_endpoint}"
  type    = "A"

  alias {
    name                   = local.nlb_dns_name
    zone_id                = local.nlb_zone_id
    evaluate_target_health = false
  }
}

output "region_endpoint" {
  description = "This region's own hostname, which reaches it whether or not it is the member of its group taking traffic. Null outside a region group, where the wildcard domain already resolves to this region."
  value       = try(aws_route53_record.catalyst_region_record[0].fqdn, null)
}

output "region_ingress_endpoint" {
  description = "The ingress endpoint to be used as argument to `diagrid region update` command"
  value       = local.region_ingress_endpoint
}

output "region_wildcard_domain" {
  description = "The region's wildcard domain"
  value       = local.wildcard_domain
}

output "route53_zone_id" {
  description = "ID of the hosted zone holding this region's records. The second region of a region group passes this as its own `route53_zone_id`, so both regions share one wildcard domain."
  value       = local.zone_id
}

output "route53_zone_name_servers" {
  description = "Name servers of the hosted zone this region created, to delegate the domain to. Null when this region joined an existing zone, which already has its own delegation."
  value       = try(aws_route53_zone.catalyst_hosted_zone[0].name_servers, null)
}

output "gateway_nlb_arn" {
  description = "ARN of the gateway Network Load Balancer the Catalyst agent created in this region. Null until the agent is installed. The region-group stack discovers this by tag, but record it and pass it as that stack's primary_gateway_lb_arn or secondary_gateway_lb_arn: with both set, the group's front door can be re-applied while a member region is unreachable."
  value       = local.nlb_arn
}
