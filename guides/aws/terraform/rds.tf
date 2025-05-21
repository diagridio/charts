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
  value       = aws_db_instance.postgresql.endpoint
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

output "postgresql_master_user_secret" {
  description = "The master user secret for the PostgreSQL RDS instance"
  value       = aws_db_instance.postgresql.master_user_secret
  sensitive   = true
}