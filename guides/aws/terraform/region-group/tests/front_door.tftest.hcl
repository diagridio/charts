# The region group's front door: one accelerator over both regions' gateway
# Load Balancers, and the wildcard domain pointing at it.
#
# These run offline. Every region lookup here is gated on the gateway Load
# Balancer the Catalyst agent creates, so a plan against an empty account
# reaches none of it. mock_provider stands in for AWS and each run supplies the
# two Load Balancers — except the last one, which supplies neither on purpose.
#
# Run with: terraform test

mock_provider "aws" { alias = "primary" }
mock_provider "aws" { alias = "secondary" }
mock_provider "aws" { alias = "global" }

# A mocked resource gets a random string for every attribute, and the endpoint
# groups reject one where an ARN belongs.
override_resource {
  target = aws_globalaccelerator_accelerator.catalyst
  values = {
    id             = "arn:aws:globalaccelerator::111122223333:accelerator/abcd1234"
    dns_name       = "a1234567890abcdef.awsglobalaccelerator.com"
    hosted_zone_id = "Z2BJ6XQ5FK7U4H"
    ip_sets = [{
      ip_family    = "IPv4"
      ip_addresses = ["198.51.100.10", "198.51.100.11"]
    }]
  }
}

override_resource {
  target = aws_globalaccelerator_listener.catalyst
  values = {
    id = "arn:aws:globalaccelerator::111122223333:accelerator/abcd1234/listener/1a2b3c4d"
  }
}

variables {
  region_ingress_endpoint = "catalyst.example.com"
  route53_zone_id         = "Z0123456789ABCDEF"

  primary_aws_region   = "us-west-2"
  primary_cluster_name = "catalyst-west"

  secondary_aws_region   = "us-east-1"
  secondary_cluster_name = "catalyst-east"
}

run "both_regions_sit_behind_one_accelerator" {
  command = apply

  override_data {
    target = data.aws_lbs.primary_gateway[0]
    values = {
      arns = ["arn:aws:elasticloadbalancing:us-west-2:111122223333:loadbalancer/net/gw/abc123"]
    }
  }


  override_data {
    target = data.aws_lbs.secondary_gateway[0]
    values = {
      arns = ["arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/net/gw/def456"]
    }
  }


  assert {
    condition     = aws_globalaccelerator_listener.catalyst.protocol == "TCP"
    error_message = "the gateway terminates TLS itself, so the accelerator must forward TCP rather than terminate anything"
  }

  assert {
    condition     = one(aws_globalaccelerator_listener.catalyst.port_range).from_port == 443 && one(aws_globalaccelerator_listener.catalyst.port_range).to_port == 443
    error_message = "the listener must carry the port the gateway serves"
  }

  assert {
    condition     = aws_globalaccelerator_endpoint_group.primary.endpoint_group_region == "us-west-2"
    error_message = "each endpoint group belongs to one member region"
  }

  assert {
    condition     = one(aws_globalaccelerator_endpoint_group.primary.endpoint_configuration).endpoint_id == "arn:aws:elasticloadbalancing:us-west-2:111122223333:loadbalancer/net/gw/abc123"
    error_message = "the first region's endpoint must be that region's own gateway Load Balancer"
  }

  assert {
    condition     = one(aws_globalaccelerator_endpoint_group.secondary.endpoint_configuration).endpoint_id == "arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/net/gw/def456"
    error_message = "the second region's endpoint must be that region's own gateway Load Balancer"
  }

  assert {
    condition     = aws_globalaccelerator_endpoint_group.primary.traffic_dial_percentage == 100 && aws_globalaccelerator_endpoint_group.secondary.traffic_dial_percentage == 100
    error_message = "both regions take traffic by default; the Load Balancer health decides which one actually does"
  }

  assert {
    condition     = aws_route53_record.wildcard.name == "*.catalyst.example.com"
    error_message = "the wildcard record must cover every name the group serves"
  }

  assert {
    condition     = one(aws_route53_record.wildcard.alias).name == aws_globalaccelerator_accelerator.catalyst.dns_name
    error_message = "the wildcard record must resolve to the accelerator, not to either region"
  }

  assert {
    condition     = output.region_endpoints.primary == "catalyst-west.catalyst.example.com"
    error_message = "each region needs a name of its own to be probed on"
  }
}

# A planned failover drains a region before its database is promoted, rather
# than letting the promotion itself move the traffic.
run "draining_a_region_leaves_it_healthy_and_takes_its_traffic_away" {
  command = apply

  variables {
    primary_traffic_dial_percentage = 0
  }

  override_data {
    target = data.aws_lbs.primary_gateway[0]
    values = {
      arns = ["arn:aws:elasticloadbalancing:us-west-2:111122223333:loadbalancer/net/gw/abc123"]
    }
  }


  override_data {
    target = data.aws_lbs.secondary_gateway[0]
    values = {
      arns = ["arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/net/gw/def456"]
    }
  }


  assert {
    condition     = aws_globalaccelerator_endpoint_group.primary.traffic_dial_percentage == 0
    error_message = "the drained region must take no new connections"
  }

  assert {
    condition     = one(aws_globalaccelerator_endpoint_group.primary.endpoint_configuration).endpoint_id == "arn:aws:elasticloadbalancing:us-west-2:111122223333:loadbalancer/net/gw/abc123"
    error_message = "draining a region must not remove it from the accelerator, or failing back means rebuilding it"
  }

  assert {
    condition     = aws_globalaccelerator_endpoint_group.secondary.traffic_dial_percentage == 100
    error_message = "the region being failed over to must keep taking traffic"
  }
}

# The Load Balancer is created by the Catalyst agent's gateway Service, so this
# stack cannot be applied before the agent is installed in both regions.
run "a_region_without_its_agent_installed_is_refused" {
  command = plan

  override_data {
    target = data.aws_lbs.primary_gateway[0]
    values = {
      arns = ["arn:aws:elasticloadbalancing:us-west-2:111122223333:loadbalancer/net/gw/abc123"]
    }
  }


  override_data {
    target = data.aws_lbs.secondary_gateway[0]
    values = {
      arns = []
    }
  }

  expect_failures = [aws_globalaccelerator_endpoint_group.secondary]
}

# Losing a region is when the traffic dial is worth reaching for, and a region
# that is down cannot answer a lookup. Given both ARNs this stack reads nothing
# from either member region, so it still plans with both of them unreachable —
# which is what the absence of any override_data here stands for.
run "the_front_door_plans_without_reading_either_member_region" {
  command = plan

  variables {
    primary_gateway_lb_arn          = "arn:aws:elasticloadbalancing:us-west-2:111122223333:loadbalancer/net/gw/abc123"
    secondary_gateway_lb_arn        = "arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/net/gw/def456"
    primary_traffic_dial_percentage = 0
  }

  assert {
    condition     = length(data.aws_lbs.primary_gateway) == 0 && length(data.aws_lbs.secondary_gateway) == 0
    error_message = "a given ARN must replace the lookup, not sit beside it — the lookup is the thing an unreachable region cannot serve"
  }

  assert {
    condition     = one(aws_globalaccelerator_endpoint_group.primary.endpoint_configuration).endpoint_id == "arn:aws:elasticloadbalancing:us-west-2:111122223333:loadbalancer/net/gw/abc123"
    error_message = "the given ARN must be the endpoint the accelerator registers"
  }

  assert {
    condition     = aws_globalaccelerator_endpoint_group.primary.traffic_dial_percentage == 0
    error_message = "draining the lost region is the point of being able to apply this at all"
  }
}

# One ARN given and the other discovered is the ordinary case part-way through
# recording them, and must behave like either one alone.
run "a_given_arn_and_a_discovered_one_mix" {
  command = plan

  variables {
    secondary_gateway_lb_arn = "arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/net/gw/def456"
  }

  override_data {
    target = data.aws_lbs.primary_gateway[0]
    values = {
      arns = ["arn:aws:elasticloadbalancing:us-west-2:111122223333:loadbalancer/net/gw/abc123"]
    }
  }

  assert {
    condition     = length(data.aws_lbs.secondary_gateway) == 0
    error_message = "the given side must not be looked up"
  }

  assert {
    condition     = one(aws_globalaccelerator_endpoint_group.primary.endpoint_configuration).endpoint_id == "arn:aws:elasticloadbalancing:us-west-2:111122223333:loadbalancer/net/gw/abc123"
    error_message = "the discovered side must still resolve by tag"
  }
}
