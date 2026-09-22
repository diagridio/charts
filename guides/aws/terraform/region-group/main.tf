# The front door for a Catalyst region group.
#
# Both member regions serve the same wildcard domain, and exactly one of them
# accepts writes at a time. This stack puts one AWS Global Accelerator in front
# of the two regions' gateway Load Balancers and points the wildcard domain at
# it, so the group has a single entry point whose backend can change without
# anything downstream re-resolving a name.
#
# Where the failover decision comes from
# --------------------------------------
# Global Accelerator does not health check a Load Balancer endpoint itself. It
# reads the health the Load Balancer already reports, which for a Network Load
# Balancer is its target group's. So the failover signal is configured on the
# Catalyst gateway Service, not here: the guide sets the gateway's target group
# health check to GET /diagrid/region/writable, which every region answers with
# 200 while its PostgreSQL accepts writes and 503 while it is a replica.
#
# The passive region's targets therefore read unhealthy, the accelerator sends
# no traffic there, and promoting the replica moves the traffic. Nothing here
# knows which region is active, and neither does Catalyst.
#
# This stack is applied once for the group, from its own state, after both
# regions have been applied and have the Catalyst agent installed.

# Each member's gateway Load Balancer, either given or discovered.
#
# Discovery is by the tags the AWS Load Balancer Controller puts on the Load
# Balancer it creates for the gateway Service, which is how a region's is found
# without being told. It costs a read in that region's account, though, and a
# region that is down cannot answer one — which would make this stack
# unplannable exactly when a member region has been lost and its traffic dial
# is the thing you want to reach for.
#
# So each member's ARN can be given instead, from that region's gateway_nlb_arn
# output. Give both and this stack reads nothing from either member region.
data "aws_lbs" "primary_gateway" {
  provider = aws.primary

  count = var.primary_gateway_lb_arn == "" ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster"    = var.primary_cluster_name
    "service.k8s.aws/stack"    = "cra-agent/gateway-envoy"
    "service.k8s.aws/resource" = "LoadBalancer"
  }
}

data "aws_lbs" "secondary_gateway" {
  provider = aws.secondary

  count = var.secondary_gateway_lb_arn == "" ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster"    = var.secondary_cluster_name
    "service.k8s.aws/stack"    = "cra-agent/gateway-envoy"
    "service.k8s.aws/resource" = "LoadBalancer"
  }
}

locals {
  discovered_primary_nlb_arns   = try(tolist(data.aws_lbs.primary_gateway[0].arns), [])
  discovered_secondary_nlb_arns = try(tolist(data.aws_lbs.secondary_gateway[0].arns), [])

  primary_nlb_arn = (var.primary_gateway_lb_arn != ""
    ? var.primary_gateway_lb_arn
  : try(local.discovered_primary_nlb_arns[0], null))
  secondary_nlb_arn = (var.secondary_gateway_lb_arn != ""
    ? var.secondary_gateway_lb_arn
  : try(local.discovered_secondary_nlb_arns[0], null))

  has_primary_nlb   = local.primary_nlb_arn != null
  has_secondary_nlb = local.secondary_nlb_arn != null
}

resource "aws_globalaccelerator_accelerator" "catalyst" {
  provider = aws.global

  name            = var.name
  ip_address_type = "IPV4"
  enabled         = true
}

# One TCP listener: the gateway terminates TLS itself and routes on SNI, so the
# accelerator must not terminate anything. SOURCE_IP affinity keeps a client on
# one region while that region stays healthy.
resource "aws_globalaccelerator_listener" "catalyst" {
  provider = aws.global

  accelerator_arn = aws_globalaccelerator_accelerator.catalyst.id
  protocol        = "TCP"
  client_affinity = var.client_affinity

  port_range {
    from_port = var.listener_port
    to_port   = var.listener_port
  }
}

resource "aws_globalaccelerator_endpoint_group" "primary" {
  provider = aws.global

  listener_arn            = aws_globalaccelerator_listener.catalyst.id
  endpoint_group_region   = var.primary_aws_region
  traffic_dial_percentage = var.primary_traffic_dial_percentage

  endpoint_configuration {
    endpoint_id = local.primary_nlb_arn
    weight      = 128
  }

  lifecycle {
    precondition {
      condition     = local.has_primary_nlb
      error_message = "No gateway Load Balancer found for cluster ${var.primary_cluster_name} in ${var.primary_aws_region}. Install the Catalyst agent in that region first — the Load Balancer is created by its gateway Service. If that region is unreachable, set primary_gateway_lb_arn to its gateway_nlb_arn output instead."
    }
  }
}

resource "aws_globalaccelerator_endpoint_group" "secondary" {
  provider = aws.global

  listener_arn            = aws_globalaccelerator_listener.catalyst.id
  endpoint_group_region   = var.secondary_aws_region
  traffic_dial_percentage = var.secondary_traffic_dial_percentage

  endpoint_configuration {
    endpoint_id = local.secondary_nlb_arn
    weight      = 128
  }

  lifecycle {
    precondition {
      condition     = local.has_secondary_nlb
      error_message = "No gateway Load Balancer found for cluster ${var.secondary_cluster_name} in ${var.secondary_aws_region}. Install the Catalyst agent in that region first — the Load Balancer is created by its gateway Service. If that region is unreachable, set secondary_gateway_lb_arn to its gateway_nlb_arn output instead."
    }
  }
}

# Every name under the domain — a project's http- and grpc- hostnames, and the
# region's service names — resolves to the accelerator's static addresses, for
# every client, with no per-region record and nothing to re-resolve on failover.
resource "aws_route53_record" "wildcard" {
  provider = aws.global

  zone_id = var.route53_zone_id
  name    = "*.${var.region_ingress_endpoint}"
  type    = "A"

  alias {
    name                   = aws_globalaccelerator_accelerator.catalyst.dns_name
    zone_id                = aws_globalaccelerator_accelerator.catalyst.hosted_zone_id
    evaluate_target_health = true
  }
}
