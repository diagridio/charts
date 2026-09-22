# How the passive region's PostgreSQL instances are built, and what happens
# when they are deleted.
#
# The delete half is what these hold. AWS takes no final snapshot of a read
# replica — DeleteDBInstance requires SkipFinalSnapshot on one and refuses a
# FinalDBSnapshotIdentifier for it — and the provider refuses to delete an
# instance whose configuration neither names a snapshot nor skips one. An
# instance carrying that pair is an instance nothing can destroy, so the two
# attributes have to move together.
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

variables {
  region_ingress_endpoint = "catalyst.example.com"
  enable_bastion          = false
  enable_peering          = false
  route53_zone_id         = ""
  region_group_member     = false
  kek_kms_enabled         = false

  scheduler_postgresql_instances = ["pg1"]
}

# The active region writes, and its instances are snapshotted on delete the way
# every single-region deployment's always have been.
run "the_writing_region_keeps_its_final_snapshot" {
  command = apply

  variables {
    cluster_name                                  = "catalyst-west"
    postgresql_replicate_source_db_arn            = ""
    scheduler_postgresql_replicate_source_db_arns = {}
  }

  override_data {
    target = data.aws_lbs.catalyst_gateway_nlb
    values = { arns = [] }
  }

  assert {
    condition     = aws_db_instance.postgresql.replicate_source_db == null
    error_message = "a region given no replication source writes; it is not a replica of anything"
  }

  assert {
    condition     = aws_db_instance.postgresql.skip_final_snapshot == false && startswith(aws_db_instance.postgresql.final_snapshot_identifier, "catalyst-west-postgresql-final-snapshot-")
    error_message = "the default is to keep a final snapshot, under a name carrying this instance's own"
  }

  assert {
    condition     = aws_db_instance.scheduler_postgresql["pg1"].skip_final_snapshot == false && startswith(aws_db_instance.scheduler_postgresql["pg1"].final_snapshot_identifier, "catalyst-west-scheduler-pg1-final-snapshot-")
    error_message = "the scheduler instances follow the same default as the shared one"
  }

  # RDS snapshot identifiers are unique per account per region. A name shared
  # across a deployment's instances lets whichever is deleted first take it and
  # fails every delete after it — which is both the second half of a failback
  # and the second half of a teardown.
  assert {
    condition     = aws_db_instance.postgresql.final_snapshot_identifier != aws_db_instance.scheduler_postgresql["pg1"].final_snapshot_identifier
    error_message = "two instances of one deployment must not name the same final snapshot"
  }

  # The name also has to differ between one instance's own incarnations. A group
  # member is destroyed and recreated on every failover, and each incarnation
  # that was a writer leaves a snapshot behind holding its name — so a name
  # fixed to the instance fails the teardown of any region that has ever failed
  # over, which is every region that follows the deployment guide's step 11.
  assert {
    condition     = endswith(aws_db_instance.postgresql.final_snapshot_identifier, tostring(time_static.postgresql_incarnation.unix))
    error_message = "the final snapshot name must carry this incarnation's stamp, or the next rebuild's delete collides with the snapshot this one leaves"
  }
}

# The passive region's instances are replicas, and a replica is deleted with no
# snapshot because AWS offers no other way to delete one.
run "a_replica_is_deletable_because_it_skips_the_snapshot_it_cannot_take" {
  command = apply

  variables {
    cluster_name                       = "catalyst-east"
    postgresql_replicate_source_db_arn = "arn:aws:rds:us-west-2:111122223333:db:catalyst-west-postgresql"
    scheduler_postgresql_replicate_source_db_arns = {
      pg1 = "arn:aws:rds:us-west-2:111122223333:db:catalyst-west-scheduler-pg1-postgresql"
    }
  }

  override_data {
    target = data.aws_lbs.catalyst_gateway_nlb
    values = { arns = [] }
  }

  assert {
    condition     = aws_db_instance.postgresql.replicate_source_db == "arn:aws:rds:us-west-2:111122223333:db:catalyst-west-postgresql"
    error_message = "the passive region's shared instance must be a replica of the active region's"
  }

  assert {
    condition     = aws_db_instance.postgresql.skip_final_snapshot == true && aws_db_instance.postgresql.final_snapshot_identifier == null
    error_message = "a replica that names no snapshot and does not skip one cannot be deleted at all: the provider refuses the combination, so the passive region could never be torn down"
  }

  assert {
    condition     = aws_db_instance.scheduler_postgresql["pg1"].skip_final_snapshot == true && aws_db_instance.scheduler_postgresql["pg1"].final_snapshot_identifier == null
    error_message = "the scheduler replicas are replicas too, and are deleted the same way"
  }
}

# Asking for a snapshot of a replica is asking for something AWS does not offer.
# The region stays deletable rather than honouring the variable.
run "a_replica_skips_the_snapshot_even_when_the_region_asks_for_one" {
  command = apply

  variables {
    cluster_name                       = "catalyst-east"
    postgresql_skip_final_snapshot     = false
    postgresql_replicate_source_db_arn = "arn:aws:rds:us-west-2:111122223333:db:catalyst-west-postgresql"
    scheduler_postgresql_replicate_source_db_arns = {
      pg1 = "arn:aws:rds:us-west-2:111122223333:db:catalyst-west-scheduler-pg1-postgresql"
    }
  }

  override_data {
    target = data.aws_lbs.catalyst_gateway_nlb
    values = { arns = [] }
  }

  assert {
    condition     = aws_db_instance.postgresql.skip_final_snapshot == true
    error_message = "postgresql_skip_final_snapshot does not apply to a replica; honouring it here would produce an instance AWS cannot delete"
  }
}
