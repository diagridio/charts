# PostgreSQL RDS Configuration

# Create a security group for the RDS instance
resource "aws_security_group" "rds_sg" {
  name        = "${var.cluster_name}-rds-sg"
  description = "Security group for PostgreSQL RDS instance"
  vpc_id      = module.vpc.vpc_id

  # Allow PostgreSQL traffic from EKS worker nodes
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
    description     = "Allow PostgreSQL access from EKS worker nodes"
  }

  # Allow PostgreSQL traffic from bastion host (if enabled)
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = var.enable_bastion ? [aws_security_group.bastion_sg[0].id] : []
    description     = "Allow PostgreSQL access from bastion host"
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "${var.cluster_name}-rds-sg"
  }
}

# Create a subnet group for the RDS instance using private subnets
resource "aws_db_subnet_group" "rds_subnet_group" {
  name        = "${var.cluster_name}-rds-subnet-group"
  description = "Subnet group for PostgreSQL RDS instance"
  subnet_ids  = module.vpc.private_subnets

  tags = {
    Name = "${var.cluster_name}-rds-subnet-group"
  }
}

# Create the PostgreSQL RDS instance
#
# An RDS snapshot identifier is unique per account per region, and stays taken
# for as long as the snapshot is kept. A region group member's database is
# destroyed and recreated on every failover — RDS has no demote API, so that is
# the only way to make a writer a replica again — and each incarnation that was
# a writer takes a final snapshot on its way out. A name fixed to the instance
# is therefore claimed by the first incarnation, and every delete after it fails
# with DBSnapshotAlreadyExists, including the region's eventual teardown.
#
# That is reachable by doing nothing but what the deployment guide asks for: its
# step 11 has the reader rehearse a full failover round trip, which rebuilds
# this instance once.
#
# So stamp the name with the moment this incarnation was built. The trigger is
# the replication source, because that is what changes when an instance is
# rebuilt as a replica or promoted back — an ordinary apply leaves it alone.
resource "time_static" "postgresql_incarnation" {
  triggers = {
    replicate_source_db = var.postgresql_replicate_source_db_arn
  }
}

# A passive region points postgresql_replicate_source_db_arn at the active
# region's instance and gets a read replica instead of a writer. Clearing the
# variable and applying again promotes it in place - that is the failover step.
resource "aws_db_instance" "postgresql" {
  identifier            = "${var.cluster_name}-postgresql"
  engine                = "postgres"
  engine_version        = var.postgresql_version
  instance_class        = var.postgresql_instance_class
  allocated_storage     = var.postgresql_allocated_storage
  max_allocated_storage = var.postgresql_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  replicate_source_db   = var.postgresql_replicate_source_db_arn != "" ? var.postgresql_replicate_source_db_arn : null
  kms_key_id            = var.postgresql_replicate_source_db_arn != "" ? module.eks.kms_key_arn : null
  db_name               = var.postgresql_replicate_source_db_arn != "" ? null : var.postgresql_db_name
  username              = var.postgresql_replicate_source_db_arn != "" ? null : var.postgresql_username
  # The provider refuses manage_master_user_password and password appearing
  # together in the configuration whatever their values, so the unused one is
  # null rather than false.
  manage_master_user_password   = var.postgresql_manage_master_user_password ? true : null
  password                      = var.postgresql_manage_master_user_password || var.postgresql_replicate_source_db_arn != "" ? null : var.postgresql_password
  master_user_secret_kms_key_id = var.postgresql_manage_master_user_password ? module.eks.kms_key_id : null
  port                          = 5432
  vpc_security_group_ids        = [aws_security_group.rds_sg.id]
  db_subnet_group_name          = aws_db_subnet_group.rds_subnet_group.name
  parameter_group_name          = aws_db_parameter_group.postgresql.name
  # AWS takes no final snapshot of a read replica: DeleteDBInstance requires
  # SkipFinalSnapshot on one and refuses a FinalDBSnapshotIdentifier for it. So
  # a replica skips whatever this region's variable says, and the pair moves
  # together — the provider refuses to delete an instance that names no snapshot
  # and does not skip one, which would leave the passive region undestroyable.
  # The identifier carries the instance's own name: RDS snapshot names are
  # unique per account per region, so a name shared with the scheduler instances
  # lets whichever is deleted first take it and fails every delete after it.
  skip_final_snapshot       = var.postgresql_replicate_source_db_arn != "" ? true : var.postgresql_skip_final_snapshot
  final_snapshot_identifier = var.postgresql_replicate_source_db_arn != "" ? null : "${var.cluster_name}-postgresql-${var.postgresql_final_snapshot_identifier}-${time_static.postgresql_incarnation.unix}"
  deletion_protection       = var.postgresql_deletion_protection
  backup_retention_period   = var.postgresql_backup_retention_period
  backup_window             = var.postgresql_backup_window
  maintenance_window        = var.postgresql_maintenance_window
  multi_az                  = var.postgresql_multi_az
  publicly_accessible       = false
  apply_immediately         = true
  # Performance Insights configuration
  performance_insights_enabled          = true
  performance_insights_retention_period = 7 # 7 days (free tier) or 731 days (paid)

  tags = {
    Name = "${var.cluster_name}-postgresql"
  }
}

# Create a parameter group for PostgreSQL
resource "aws_db_parameter_group" "postgresql" {
  name        = "${var.cluster_name}-postgresql-params"
  family      = "postgres${split(".", var.postgresql_version)[0]}"
  description = "Parameter group for PostgreSQL RDS instance"

  # Add any custom parameters here
  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  # The Dapr scheduler opens a logical replication connection to its database,
  # and by default that database is this one: the chart's scheduler default is
  # backend_type: postgresql with postgresql.use_global: true, which puts the
  # scheduler's jobs and actor reminders in a `sched` database on the managed
  # state store rather than on an instance of its own. A region group's members
  # are required to run it that way (scheduler_postgresql_instances = []), so
  # for them this is not optional.
  #
  # Without it wal_level stays `replica`, RDS grants the master user no
  # rds_replication role and writes no replication entry into pg_hba.conf, and
  # every scheduler replica crash-loops on
  #   FATAL: no pg_hba.conf entry for host "...", user "postgres",
  #          database "sched", SSL encryption (SQLSTATE 28000)
  # which costs the region all jobs and actor reminders.
  #
  # Static, so a new instance picks it up as it is created and an existing one
  # needs a reboot: after applying this to a deployment that predates it, run
  #   aws rds reboot-db-instance --db-instance-identifier <cluster_name>-postgresql
  # and wait for ParameterApplyStatus to go pending-reboot -> in-sync.
  #
  # A region group's passive member runs its scheduler against a read replica,
  # and logical decoding on a standby needs PostgreSQL 16 or later. That is not
  # a constraint on postgresql_version for a single region, where the scheduler
  # reads a primary — but a group pinned below 16 has a passive region whose
  # scheduler cannot start.
  parameter {
    apply_method = "pending-reboot"
    name         = "rds.logical_replication"
    value        = "1"
  }

  tags = {
    Name = "${var.cluster_name}-postgresql-params"
  }
}

# Output the RDS connection information
output "postgresql_endpoint" {
  description = "The connection endpoint for the PostgreSQL RDS instance"
  value       = aws_db_instance.postgresql.address
}

output "postgresql_port" {
  description = "The port for the PostgreSQL RDS instance"
  value       = aws_db_instance.postgresql.port
}

output "postgresql_database_name" {
  description = "The database name for the PostgreSQL RDS instance"
  value       = aws_db_instance.postgresql.db_name
}

output "postgresql_username" {
  description = "The master username for the PostgreSQL RDS instance"
  value       = aws_db_instance.postgresql.username
}

output "postgresql_master_user_secret_arn" {
  description = "The master user secret arn from secretmanager for the PostgreSQL RDS instance, null when postgresql_manage_master_user_password is false"
  value       = try(aws_db_instance.postgresql.master_user_secret[0].secret_arn, null)
  sensitive   = true
}

output "postgresql_arn" {
  description = "ARN of the PostgreSQL RDS instance. Feed this to the other region's postgresql_replicate_source_db_arn to make its shared PostgreSQL a read replica of this one."
  value       = aws_db_instance.postgresql.arn
}

# Scheduler PostgreSQL RDS Configuration

# Create a security group for each scheduler RDS instance
resource "aws_security_group" "scheduler_rds_sg" {
  for_each    = toset(var.scheduler_postgresql_instances)
  name        = "${var.cluster_name}-scheduler-${each.key}-rds-sg"
  description = "Security group for ${each.key} Scheduler PostgreSQL RDS instance"
  vpc_id      = module.vpc.vpc_id

  # Allow PostgreSQL traffic from EKS worker nodes
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
    description     = "Allow PostgreSQL access from EKS worker nodes"
  }

  # Allow PostgreSQL traffic from bastion host (if enabled)
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = var.enable_bastion ? [aws_security_group.bastion_sg[0].id] : []
    description     = "Allow PostgreSQL access from bastion host"
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "${var.cluster_name}-scheduler-${each.key}-rds-sg"
  }
}

# Create a subnet group for each scheduler RDS instance using private subnets
resource "aws_db_subnet_group" "scheduler_rds_subnet_group" {
  for_each    = toset(var.scheduler_postgresql_instances)
  name        = "${var.cluster_name}-scheduler-${each.key}-rds-subnet-group"
  description = "Subnet group for ${each.key} Scheduler PostgreSQL RDS instance"
  subnet_ids  = module.vpc.private_subnets

  tags = {
    Name = "${var.cluster_name}-scheduler-${each.key}-rds-subnet-group"
  }
}

# Replication source per scheduler instance, empty for the ones this region writes.
locals {
  scheduler_replicate_source_db_arns = {
    for k in var.scheduler_postgresql_instances :
    k => lookup(var.scheduler_postgresql_replicate_source_db_arns, k, "")
  }
}

# Create each Scheduler PostgreSQL RDS instance
# Per scheduler instance, for the same reason as the shared one above.
resource "time_static" "scheduler_postgresql_incarnation" {
  for_each = toset(var.scheduler_postgresql_instances)
  triggers = {
    replicate_source_db = local.scheduler_replicate_source_db_arns[each.key]
  }
}

resource "aws_db_instance" "scheduler_postgresql" {
  for_each              = toset(var.scheduler_postgresql_instances)
  identifier            = "${var.cluster_name}-scheduler-${each.key}-postgresql"
  engine                = "postgres"
  engine_version        = var.postgresql_version
  instance_class        = var.postgresql_scheduler_instance_class
  allocated_storage     = var.postgresql_allocated_storage
  max_allocated_storage = var.postgresql_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  replicate_source_db   = local.scheduler_replicate_source_db_arns[each.key] != "" ? local.scheduler_replicate_source_db_arns[each.key] : null
  kms_key_id            = local.scheduler_replicate_source_db_arns[each.key] != "" ? module.eks.kms_key_arn : null
  db_name               = local.scheduler_replicate_source_db_arns[each.key] != "" ? null : var.postgresql_scheduler_db_name
  username              = local.scheduler_replicate_source_db_arns[each.key] != "" ? null : var.postgresql_scheduler_username
  # The provider refuses manage_master_user_password and password appearing
  # together in the configuration whatever their values, so the unused one is
  # null rather than false.
  manage_master_user_password   = var.postgresql_manage_master_user_password ? true : null
  password                      = var.postgresql_manage_master_user_password || local.scheduler_replicate_source_db_arns[each.key] != "" ? null : var.postgresql_password
  master_user_secret_kms_key_id = var.postgresql_manage_master_user_password ? module.eks.kms_key_id : null
  port                          = 5432
  vpc_security_group_ids        = [aws_security_group.scheduler_rds_sg[each.key].id]
  db_subnet_group_name          = aws_db_subnet_group.scheduler_rds_subnet_group[each.key].name
  parameter_group_name          = aws_db_parameter_group.scheduler_postgresql[each.key].name
  # Same pairing as the shared instance above.
  skip_final_snapshot       = local.scheduler_replicate_source_db_arns[each.key] != "" ? true : var.postgresql_skip_final_snapshot
  final_snapshot_identifier = local.scheduler_replicate_source_db_arns[each.key] != "" ? null : "${var.cluster_name}-scheduler-${each.key}-${var.postgresql_final_snapshot_identifier}-${time_static.scheduler_postgresql_incarnation[each.key].unix}"
  deletion_protection       = var.postgresql_deletion_protection
  backup_retention_period   = var.postgresql_backup_retention_period
  backup_window             = var.postgresql_backup_window
  maintenance_window        = var.postgresql_maintenance_window
  # multi_az               = var.postgresql_multi_az
  multi_az            = false
  publicly_accessible = false
  apply_immediately   = true
  # Performance Insights configuration
  performance_insights_enabled          = true
  performance_insights_retention_period = 7 # 7 days (free tier) or 731 days (paid)

  tags = {
    Name = "${var.cluster_name}-scheduler-${each.key}-postgresql"
  }
}

# Create a parameter group for each Scheduler PostgreSQL instance
resource "aws_db_parameter_group" "scheduler_postgresql" {
  for_each    = toset(var.scheduler_postgresql_instances)
  name        = "${var.cluster_name}-scheduler-${each.key}-postgresql-params"
  family      = "postgres${split(".", var.postgresql_version)[0]}"
  description = "Parameter group for ${each.key} Scheduler PostgreSQL RDS instance"

  # Add any custom parameters here
  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    apply_method = "pending-reboot"
    name         = "rds.logical_replication"
    value        = "1"
  }

  tags = {
    Name = "${var.cluster_name}-scheduler-${each.key}-postgresql-params"
  }
}

# Output the RDS connection information for all scheduler instances
output "scheduler_postgresql_endpoints" {
  description = "Map of connection endpoints for all Scheduler PostgreSQL RDS instances"
  value       = { for k, v in aws_db_instance.scheduler_postgresql : k => v.address }
}

output "scheduler_postgresql_ports" {
  description = "Map of ports for all Scheduler PostgreSQL RDS instances"
  value       = { for k, v in aws_db_instance.scheduler_postgresql : k => v.port }
}

output "scheduler_postgresql_database_names" {
  description = "Map of database names for all Scheduler PostgreSQL RDS instances"
  value       = { for k, v in aws_db_instance.scheduler_postgresql : k => v.db_name }
}

output "scheduler_postgresql_usernames" {
  description = "Map of master usernames for all Scheduler PostgreSQL RDS instances"
  value       = { for k, v in aws_db_instance.scheduler_postgresql : k => v.username }
}

output "scheduler_postgresql_master_user_secret_arns" {
  description = "Map of master user secret arns from secretmanager for all Scheduler PostgreSQL RDS instances, null per instance when postgresql_manage_master_user_password is false"
  value       = { for k, v in aws_db_instance.scheduler_postgresql : k => try(v.master_user_secret[0].secret_arn, null) }
  sensitive   = true
}

output "scheduler_postgresql_arns" {
  description = "Map of ARNs for all Scheduler PostgreSQL RDS instances. Feed this to the other region's scheduler_postgresql_replicate_source_db_arns to make its scheduler instances read replicas of these."
  value       = { for k, v in aws_db_instance.scheduler_postgresql : k => v.arn }
}
