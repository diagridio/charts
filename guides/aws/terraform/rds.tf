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
resource "aws_db_instance" "postgresql" {
  identifier             = "${var.cluster_name}-postgresql"
  engine                 = "postgres"
  engine_version         = var.postgresql_version
  instance_class         = var.postgresql_instance_class
  allocated_storage      = var.postgresql_allocated_storage
  max_allocated_storage  = var.postgresql_max_allocated_storage
  storage_type           = "gp3"
  storage_encrypted      = true
  db_name                = var.postgresql_db_name
  username               = var.postgresql_username
  manage_master_user_password = true
  master_user_secret_kms_key_id = module.eks.kms_key_id
  port                   = 5432
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name
  parameter_group_name   = aws_db_parameter_group.postgresql.name
  skip_final_snapshot    = var.postgresql_skip_final_snapshot
  final_snapshot_identifier = var.postgresql_final_snapshot_identifier
  deletion_protection    = var.postgresql_deletion_protection
  backup_retention_period = var.postgresql_backup_retention_period
  backup_window          = var.postgresql_backup_window
  maintenance_window     = var.postgresql_maintenance_window
  multi_az               = var.postgresql_multi_az
  publicly_accessible    = false
  apply_immediately      = true
  # Performance Insights configuration
  performance_insights_enabled          = true
  performance_insights_retention_period = 7  # 7 days (free tier) or 731 days (paid)

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
  description = "The master user secret arn from secretmanager for the PostgreSQL RDS instance"
  value       = aws_db_instance.postgresql.master_user_secret[0].secret_arn
  sensitive   = true
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

# Create each Scheduler PostgreSQL RDS instance
resource "aws_db_instance" "scheduler_postgresql" {
  for_each               = toset(var.scheduler_postgresql_instances)
  identifier             = "${var.cluster_name}-scheduler-${each.key}-postgresql"
  engine                 = "postgres"
  engine_version         = var.postgresql_version
  instance_class         = var.postgresql_scheduler_instance_class
  allocated_storage      = var.postgresql_allocated_storage
  max_allocated_storage  = var.postgresql_max_allocated_storage
  storage_type           = "gp3"
  storage_encrypted      = true
  db_name                = var.postgresql_scheduler_db_name
  username               = var.postgresql_scheduler_username
  manage_master_user_password = true
  master_user_secret_kms_key_id = module.eks.kms_key_id
  port                   = 5432
  vpc_security_group_ids = [aws_security_group.scheduler_rds_sg[each.key].id]
  db_subnet_group_name   = aws_db_subnet_group.scheduler_rds_subnet_group[each.key].name
  parameter_group_name   = aws_db_parameter_group.scheduler_postgresql[each.key].name
  skip_final_snapshot    = var.postgresql_skip_final_snapshot
  final_snapshot_identifier = var.postgresql_final_snapshot_identifier
  deletion_protection    = var.postgresql_deletion_protection
  backup_retention_period = var.postgresql_backup_retention_period
  backup_window          = var.postgresql_backup_window
  maintenance_window     = var.postgresql_maintenance_window
  # multi_az               = var.postgresql_multi_az
  multi_az               = false
  publicly_accessible    = false
  apply_immediately      = true
  # Performance Insights configuration
  performance_insights_enabled          = true
  performance_insights_retention_period = 7  # 7 days (free tier) or 731 days (paid)

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
    name  = "rds.logical_replication"
    value = "1"
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
  description = "Map of master user secret arns from secretmanager for all Scheduler PostgreSQL RDS instances"
  value       = { for k, v in aws_db_instance.scheduler_postgresql : k => v.master_user_secret[0].secret_arn }
  sensitive   = true
}
