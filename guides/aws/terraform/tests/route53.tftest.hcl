# Route 53 wiring for a single region, and for a region that is a member of a
# Catalyst region group.
#
# These run offline. A plan against a real AWS account cannot reach any of this:
# every Route 53 resource here is gated on the gateway Load Balancer, which the
# Catalyst agent creates after the first apply, so an empty account plans none of
# them. mock_provider stands in for AWS, override_module supplies the VPC and EKS
# outputs this stack consumes, and each run supplies the Load Balancer.
#
# Run with: terraform test

mock_provider "aws" {}
mock_provider "time" {}
mock_provider "tls" {}
mock_provider "local" {}

# The VPC and EKS modules are not what these tests are about, and planning them
# under a mocked provider fails on the IAM policy documents they build.
override_module {
  target = module.vpc
  outputs = {
    vpc_id                  = "vpc-0123456789abcdef0"
    private_subnets         = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
    public_subnets          = ["subnet-ddd", "subnet-eee", "subnet-fff"]
    private_route_table_ids = ["rtb-aaa", "rtb-bbb", "rtb-ccc"]
  }
}

override_module {
  target = module.eks
  outputs = {
    node_security_group_id = "sg-0123456789abcdef0"
    kms_key_arn            = "arn:aws:kms:us-west-2:111122223333:key/11111111-2222-3333-4444-555555555555"
    kms_key_id             = "11111111-2222-3333-4444-555555555555"
    oidc_provider          = "oidc.eks.us-west-2.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E"
    oidc_provider_arn      = "arn:aws:iam::111122223333:oidc-provider/oidc.eks.us-west-2.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E"
    eks_managed_node_groups = {
      workers = { iam_role_name = "catalyst-west-workers" }
    }
  }
}

# A mocked aws_iam_policy gets a random string for its arn, which the policy
# attachments then reject as malformed.
override_resource {
  target = aws_iam_policy.certmanager_route53_policy
  values = {
    arn = "arn:aws:iam::111122223333:policy/catalyst-certmanager-route53"
  }
}

override_resource {
  target = aws_iam_policy.aws_load_balancer_controller_policy
  values = {
    arn = "arn:aws:iam::111122223333:policy/catalyst-aws-load-balancer-controller"
  }
}

variables {
  region_ingress_endpoint = "catalyst.example.com"
  enable_bastion          = false
  enable_peering          = false

  # Pinned so that a terraform.tfvars left in this directory cannot change what
  # these runs are testing. Each run sets the ones it is about.
  route53_zone_id     = ""
  region_group_member = false
}

# A single region, unchanged by the region group variables: it creates its own
# hosted zone and one alias record pointing at its own Load Balancer.
run "single_region_creates_its_own_zone_and_record" {
  command = apply

  variables {
    cluster_name = "catalyst-west"
  }

  override_data {
    target = data.aws_lbs.catalyst_gateway_nlb
    values = {
      arns = ["arn:aws:elasticloadbalancing:us-west-2:111122223333:loadbalancer/net/gw/abc123"]
    }
  }

  override_data {
    target = data.aws_lb.catalyst_gateway_nlb[0]
    values = {
      dns_name = "gw-abc123.elb.us-west-2.amazonaws.com"
      zone_id  = "Z18D5FSROUN65G"
    }
  }

  assert {
    condition     = length(aws_route53_zone.catalyst_hosted_zone) == 1
    error_message = "a region not given a route53_zone_id must create its own hosted zone"
  }

  assert {
    condition     = aws_route53_record.catalyst_nlb_wildcard_record[0].name == "*.catalyst.example.com"
    error_message = "the wildcard record must cover the region ingress endpoint"
  }

  assert {
    condition     = one(aws_route53_record.catalyst_nlb_wildcard_record[0].alias).name == "gw-abc123.elb.us-west-2.amazonaws.com"
    error_message = "a single region's wildcard record points at that region's own Load Balancer"
  }

  assert {
    condition     = length(aws_route53_record.catalyst_region_record) == 0
    error_message = "a standalone region is already reached at its wildcard; a second name for it would be dead weight"
  }

  assert {
    condition     = output.region_endpoint == null
    error_message = "a region with no name of its own must report none, rather than one that does not resolve"
  }
}

# A member of a region group: it joins the first region's zone, leaves the
# wildcard to the front door — both regions serve the same names, so that name
# can only resolve to one thing — and writes one record of its own, the name
# that reaches this region alone.
run "group_member_joins_the_zone_and_leaves_the_domain_to_the_front_door" {
  command = apply

  variables {
    cluster_name        = "catalyst-east"
    route53_zone_id     = "Z0123456789ABCDEF"
    region_group_member = true
  }

  override_data {
    target = data.aws_lbs.catalyst_gateway_nlb
    values = {
      arns = ["arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/net/gw/def456"]
    }
  }

  override_data {
    target = data.aws_lb.catalyst_gateway_nlb[0]
    values = {
      dns_name = "gw-def456.elb.us-east-1.amazonaws.com"
      zone_id  = "Z26RNL4JYFTOTI"
    }
  }

  assert {
    condition     = length(aws_route53_zone.catalyst_hosted_zone) == 0
    error_message = "a region given a route53_zone_id must not create a second zone for the same name"
  }

  assert {
    condition     = length(aws_route53_record.catalyst_nlb_wildcard_record) == 0
    error_message = "a group member must not claim the wildcard domain the front door owns"
  }

  assert {
    condition     = output.route53_zone_id == "Z0123456789ABCDEF"
    error_message = "the region must report the zone it joined, which is what the region-group stack is given"
  }

  assert {
    condition     = output.gateway_nlb_arn == "arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/net/gw/def456"
    error_message = "the region must report the Load Balancer the accelerator will send traffic to"
  }

  assert {
    condition     = aws_route53_record.catalyst_region_record[0].name == "catalyst-east.catalyst.example.com"
    error_message = "a group member needs a name of its own, because its wildcard resolves to the front door"
  }

  assert {
    condition     = one(aws_route53_record.catalyst_region_record[0].alias).name == "gw-def456.elb.us-east-1.amazonaws.com"
    error_message = "a region's own name must bypass the accelerator and reach that region's Load Balancer"
  }

  assert {
    condition     = one(aws_route53_record.catalyst_region_record[0].alias).evaluate_target_health == false
    error_message = "a passive region's name must keep resolving, or it cannot be asked whether it accepts writes"
  }
}

# The first region of a group creates the zone and looks like a single region
# otherwise, so nothing can infer that it is grouped. Forgetting the flag there
# is caught by the second region's apply instead.
run "joining_a_zone_without_being_marked_a_group_member_is_refused" {
  # The precondition stops the plan, so there is no apply to run.
  command = plan

  variables {
    cluster_name        = "catalyst-east"
    route53_zone_id     = "Z0123456789ABCDEF"
    region_group_member = false
  }

  override_data {
    target = data.aws_lbs.catalyst_gateway_nlb
    values = {
      arns = ["arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/net/gw/def456"]
    }
  }

  override_data {
    target = data.aws_lb.catalyst_gateway_nlb[0]
    values = {
      dns_name = "gw-def456.elb.us-east-1.amazonaws.com"
      zone_id  = "Z26RNL4JYFTOTI"
    }
  }

  expect_failures = [aws_route53_record.catalyst_nlb_wildcard_record]
}
