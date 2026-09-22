# The key encryption key the PostgreSQL secrets provider seals data encryption
# keys with, and the role the Catalyst pods assume to use it.
#
# These run offline against a mocked provider. What they hold is the shape a
# region group depends on: one multi-region key created by the first region, a
# replica of that same key in the second, and a key id that is identical in
# both — because the control plane compares the key each member was configured
# with, not the key it resolves to.
#
# Run with: terraform test

mock_provider "aws" {}
mock_provider "time" {}
mock_provider "tls" {}
mock_provider "local" {}

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

override_resource {
  target = aws_iam_policy.catalyst_kek[0]
  values = {
    arn = "arn:aws:iam::111122223333:policy/catalyst-kek"
  }
}

variables {
  region_ingress_endpoint = "catalyst.example.com"
  enable_bastion          = false
  enable_peering          = false
  route53_zone_id         = ""
  region_group_member     = false

  kek_kms_enabled                = false
  kek_kms_replica_source_key_arn = ""
}

# A single region has nothing to share a key with, so nothing is created and an
# existing deployment plans unchanged.
run "a_single_region_creates_no_kek" {
  command = apply

  variables {
    cluster_name = "catalyst-west"
  }

  override_data {
    target = data.aws_lbs.catalyst_gateway_nlb
    values = { arns = [] }
  }

  assert {
    condition     = length(aws_kms_key.catalyst_kek) == 0 && length(aws_kms_replica_key.catalyst_kek) == 0
    error_message = "the KEK is opt-in; a region that did not ask for one must not get one"
  }

  assert {
    condition     = length(aws_iam_role.catalyst_kek) == 0
    error_message = "no key means no role to use it"
  }

  assert {
    condition     = output.kek_kms_role_arn == null
    error_message = "a region with no KEK role must report none, not an empty string a values file would carry into an annotation"
  }
}

# The first region of a group mints the key the group shares.
run "the_first_region_creates_a_multi_region_primary_key" {
  command = apply

  variables {
    cluster_name    = "catalyst-west"
    kek_kms_enabled = true
  }

  override_data {
    target = data.aws_lbs.catalyst_gateway_nlb
    values = { arns = [] }
  }

  override_resource {
    target = aws_kms_key.catalyst_kek[0]
    values = {
      arn    = "arn:aws:kms:us-west-2:111122223333:key/mrk-abcdef"
      key_id = "mrk-abcdef"
    }
  }

  assert {
    condition     = aws_kms_key.catalyst_kek[0].multi_region == true
    error_message = "a key the other region cannot replicate cannot be the group's key"
  }

  assert {
    condition     = length(aws_kms_replica_key.catalyst_kek) == 0
    error_message = "the region that mints the key is not replicating one"
  }

  assert {
    condition     = output.kek_kms_key_id == "mrk-abcdef"
    error_message = "the key id is what both regions configure, so it has to be reported"
  }

  assert {
    condition     = contains(jsondecode(aws_iam_role.catalyst_kek[0].assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.us-west-2.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E:sub"], "system:serviceaccount:cra-agent:catalyst-agent-sa")
    error_message = "the agent's service account must be able to assume the role, or the agent cannot unseal a secret"
  }

  assert {
    condition     = contains(jsondecode(aws_iam_role.catalyst_kek[0].assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.us-west-2.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E:sub"], "system:serviceaccount:cra-agent:catalyst-management-sa")
    error_message = "the management service reads secrets too"
  }

  assert {
    condition     = toset(jsondecode(aws_iam_policy.catalyst_kek[0].policy).Statement[0].Action) == toset(["kms:Encrypt", "kms:Decrypt"])
    error_message = "the secrets provider calls Encrypt and Decrypt and nothing else; granting more is granting more than it uses"
  }

  assert {
    condition     = jsondecode(aws_iam_policy.catalyst_kek[0].policy).Statement[0].Resource == "arn:aws:kms:us-west-2:111122223333:key/mrk-abcdef"
    error_message = "the grant must name this region's own copy of the key"
  }
}

# The second region replicates the first region's key rather than minting one,
# which is what makes both members resolve the same key identity.
run "the_second_region_replicates_that_key" {
  command = apply

  variables {
    cluster_name                   = "catalyst-east"
    kek_kms_enabled                = true
    kek_kms_replica_source_key_arn = "arn:aws:kms:us-west-2:111122223333:key/mrk-abcdef"
  }

  override_data {
    target = data.aws_lbs.catalyst_gateway_nlb
    values = { arns = [] }
  }

  override_resource {
    target = aws_kms_replica_key.catalyst_kek[0]
    values = {
      arn    = "arn:aws:kms:us-east-1:111122223333:key/mrk-abcdef"
      key_id = "mrk-abcdef"
    }
  }

  assert {
    condition     = length(aws_kms_key.catalyst_kek) == 0
    error_message = "a second primary key would be a second key: the group's secrets would be unreadable in one of its regions"
  }

  assert {
    condition     = aws_kms_replica_key.catalyst_kek[0].primary_key_arn == "arn:aws:kms:us-west-2:111122223333:key/mrk-abcdef"
    error_message = "the replica must be a replica of the first region's key"
  }

  assert {
    condition     = output.kek_kms_key_id == "mrk-abcdef"
    error_message = "a multi-region key and its replica share one key id, and that shared id is what both regions configure"
  }

  assert {
    condition     = jsondecode(aws_iam_policy.catalyst_kek[0].policy).Statement[0].Resource == "arn:aws:kms:us-east-1:111122223333:key/mrk-abcdef"
    error_message = "each region grants access to its own copy; the other region's ARN is not usable from here"
  }
}
