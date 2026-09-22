# Where the Dapr scheduler's database lives, and what that database needs.
#
# The chart's scheduler default is backend_type: postgresql with
# postgresql.use_global: true, which keeps the scheduler's jobs and actor
# reminders in a `sched` database on the managed state store — the instance
# aws_db_instance.postgresql builds — rather than on one of its own. A region
# group's members are required to run it that way, because the group's whole
# safety argument rests on there being one replicated database with one writer.
#
# The scheduler reaches that database over a logical replication connection, so
# the instance hosting it needs rds.logical_replication. Without it wal_level
# stays `replica`, RDS writes no replication entry into pg_hba.conf, and every
# scheduler replica crash-loops on SQLSTATE 28000 — the region comes up with no
# jobs and no actor reminders, which is the one thing a region group exists to
# preserve across a failover.
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
}

# The default matches the chart's default, so a deployment that says nothing
# about the scheduler builds no instance for it and does not pay for one it
# never connects to. This is the case the old ["pg1"] default got wrong.
run "the_default_builds_no_scheduler_instance" {
  command = apply

  variables {
    cluster_name                       = "catalyst-west"
    postgresql_replicate_source_db_arn = ""
    # scheduler_postgresql_instances deliberately unset: this asserts the default.
  }

  override_data {
    target = data.aws_lbs.catalyst_gateway_nlb
    values = { arns = [] }
  }

  assert {
    condition     = length(aws_db_instance.scheduler_postgresql) == 0
    error_message = "the default must build no dedicated scheduler instance: the chart's scheduler default is use_global: true, so an instance built here is one nothing connects to"
  }
}

# A region group's member runs the scheduler on the shared database and builds
# no instance for it. That database is therefore the one that has to allow a
# logical replication connection.
run "a_group_member_hosts_the_scheduler_on_the_shared_database" {
  command = apply

  variables {
    cluster_name                       = "catalyst-west"
    scheduler_postgresql_instances     = []
    postgresql_replicate_source_db_arn = ""
  }

  override_data {
    target = data.aws_lbs.catalyst_gateway_nlb
    values = { arns = [] }
  }

  assert {
    condition     = length(aws_db_instance.scheduler_postgresql) == 0
    error_message = "scheduler_postgresql_instances = [] must build no scheduler instance: the group keeps the scheduler in the shared database so there is one replication stream and one writer"
  }

  assert {
    condition = length([
      for p in aws_db_parameter_group.postgresql.parameter :
      p if p.name == "rds.logical_replication" && p.value == "1"
    ]) == 1
    error_message = "the shared database hosts the Dapr scheduler, which connects to it by logical replication; without rds.logical_replication = 1 the scheduler crash-loops on 'no pg_hba.conf entry ... SSL encryption' and the region has no jobs or actor reminders"
  }
}

# It is not conditional on the group, because it is not conditional on the
# variable either: the chart puts the scheduler on this database by default, so
# a single-region deployment that never mentions the scheduler needs it too.
run "a_single_region_needs_it_just_the_same" {
  command = apply

  variables {
    cluster_name                                  = "catalyst-west"
    scheduler_postgresql_instances                = ["pg1"]
    postgresql_replicate_source_db_arn            = ""
    scheduler_postgresql_replicate_source_db_arns = {}
  }

  override_data {
    target = data.aws_lbs.catalyst_gateway_nlb
    values = { arns = [] }
  }

  assert {
    condition = length([
      for p in aws_db_parameter_group.postgresql.parameter :
      p if p.name == "rds.logical_replication" && p.value == "1"
    ]) == 1
    error_message = "the chart's scheduler default is use_global: true whatever scheduler_postgresql_instances says, so the shared database allows logical replication in a single-region deployment as well"
  }

  # The dedicated instances have always had it. Stated here so that the two
  # cannot drift apart: whichever instance ends up hosting the scheduler, it
  # allows the connection the scheduler makes.
  assert {
    condition = length([
      for p in aws_db_parameter_group.scheduler_postgresql["pg1"].parameter :
      p if p.name == "rds.logical_replication" && p.value == "1"
    ]) == 1
    error_message = "a dedicated scheduler instance hosts the scheduler and needs the same parameter"
  }
}

# Allowing the connection is half of it. The passive member makes it against a
# read replica, and a standby could not decode logically before PostgreSQL 16 —
# so a group pinned below it has a region whose scheduler cannot start however
# the parameter is set. The guard belongs at plan time, because the symptom is
# three crash-looping pods in a namespace the guide never asks anyone to open.
run "a_group_member_below_postgresql_16_is_refused" {
  command = plan

  variables {
    cluster_name                       = "catalyst-west"
    scheduler_postgresql_instances     = []
    postgresql_version                 = "15.7"
    postgresql_replicate_source_db_arn = "arn:aws:rds:us-east-2:111122223333:db:catalyst-east-postgresql"
  }

  expect_failures = [var.postgresql_version]
}

# And it is only the passive member's constraint. A single region's scheduler
# decodes from a writer, which every supported engine can do.
run "a_single_region_below_postgresql_16_is_allowed" {
  command = plan

  variables {
    cluster_name                                  = "catalyst-west"
    scheduler_postgresql_instances                = []
    postgresql_version                            = "15.7"
    postgresql_replicate_source_db_arn            = ""
    scheduler_postgresql_replicate_source_db_arns = {}
  }
}
