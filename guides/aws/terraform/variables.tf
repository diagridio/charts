variable "aws_region" {
  description = "AWS region for all resources"
  default     = "us-west-2"
}

variable "tags" {
  description = "Tags to apply to all AWS resources"
  type        = map(string)
  default     = {}
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  default     = "catalyst"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  default     = "1.32"
}

variable "region_ingress_endpoint" {
  description = "Catalyst regional ingress endpoint"
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  default     = "10.0.0.0/16"
}

variable "enable_peering" {
  description = "Whether to enable VPC peering"
  type        = bool
  default     = true
}

variable "peer_vpc_id" {
  description = "VPC ID of external/customer VPC to peer with"
  type        = string
  default     = ""
}

variable "peer_vpc_cidr" {
  description = "CIDR block of the external VPC for routing"
  type        = string
  default     = ""
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes"
  default     = "c5.large" # Compute-optimized instance with good network performance
}

variable "node_min_capacity" {
  description = "Minimum number of worker nodes"
  default     = 2
}

variable "node_max_capacity" {
  description = "Maximum number of worker nodes"
  default     = 5
}

variable "node_desired_capacity" {
  description = "Desired number of worker nodes at launch"
  default     = 2
}

variable "enable_bastion" {
  description = "Whether to deploy a bastion host for cluster access"
  type        = bool
  default     = true
}

variable "bastion_instance_type" {
  description = "EC2 instance type for the bastion host"
  default     = "t3.micro" # Small instance type sufficient for bastion
}

variable "bastion_key_name" {
  description = "SSH key name for the bastion host (optional, will be auto-generated if not provided)"
  type        = string
  default     = ""
}

variable "bastion_allowed_cidr" {
  description = "CIDR blocks allowed to SSH to the bastion host"
  type        = string
  default     = "0.0.0.0/0" # Should be restricted in production
}

variable "bastion_allowed_iam_users" {
  description = "List of IAM user ARNs allowed to connect to the bastion host using EC2 Instance Connect"
  type        = list(string)
  default     = []
}

variable "bastion_allowed_iam_roles" {
  description = "List of IAM role ARNs allowed to connect to the bastion host using EC2 Instance Connect"
  type        = list(string)
  default     = []
}

variable "enable_bastion_ssh_key" {
  description = "Whether to enable SSH key-based authentication for the bastion host"
  type        = bool
  default     = false
}

# Variable to control whether to use the most recent AMI
variable "bastion_use_most_recent_ami" {
  description = "Whether to use the most recent AMI or stick to a specific version"
  type        = bool
  default     = false
}

# Variable for the specific AMI name when not using most recent.
# NOTE: Amazon deregisters old AL2023 AMIs over time, which makes `terraform plan`
# fail with "Your query returned no results". When that happens, update this
# default to a currently available AMI:
#   aws ec2 describe-images --owners amazon \
#     --filters "Name=name,Values=al2023-ami-2023.*-kernel-6.*-x86_64" \
#     --query 'reverse(sort_by(Images,&CreationDate))[0].Name' --output text
# or override it without editing this file:
#   TF_VAR_bastion_specific_ami_name=<ami-name> make plan
variable "bastion_specific_ami_name" {
  description = "Specific AMI name to use when use_most_recent_ami is false"
  type        = string
  default     = "al2023-ami-2023.12.20260724.0-kernel-6.1-x86_64"
}

variable "ebs_csi_addon_version" {
  description = "Version of the EBS CSI driver addon for EKS"
  type        = string
  default     = "v1.42.0-eksbuild.1"
}

variable "coredns_addon_version" {
  description = "Version of the CoreDNS addon for EKS"
  type        = string
  default     = "v1.11.4-eksbuild.2"
}

variable "eks_admin_roles" {
  description = "List of IAM role ARNs to grant admin access to the EKS cluster"
  type        = list(string)
  default     = []
}

variable "eks_admin_users" {
  description = "List of IAM user ARNs to grant admin access to the EKS cluster"
  type        = list(string)
  default     = []
}

variable "eks_readonly_roles" {
  description = "List of IAM role ARNs to grant read-only access to the EKS cluster"
  type        = list(string)
  default     = []
}

variable "eks_readonly_users" {
  description = "List of IAM user ARNs to grant read-only access to the EKS cluster"
  type        = list(string)
  default     = []
}

# PostgreSQL RDS Variables
variable "postgresql_version" {
  description = "PostgreSQL engine version. A region group's passive member needs 16 or later: its scheduler runs logical decoding against a read replica, and a standby cannot decode before 16."
  type        = string
  default     = "17.5"

  # The Dapr scheduler reaches its database over a logical replication
  # connection. In a single region that database is a writer, which decodes on
  # any supported engine. A group's passive member points
  # postgresql_replicate_source_db_arn at the other region and runs the same
  # scheduler against a standby, and logical decoding on a standby arrived in
  # PostgreSQL 16 - so a group pinned below it has a passive region whose
  # scheduler never starts, three pods deep in a namespace the guide never
  # asks anyone to look at. Fail at plan time instead.
  validation {
    condition     = var.postgresql_replicate_source_db_arn == "" || tonumber(split(".", var.postgresql_version)[0]) >= 16
    error_message = "A region group's passive member needs postgresql_version 16 or later; logical decoding on a read replica is not available before it."
  }
}

variable "postgresql_instance_class" {
  description = "Instance class for the PostgreSQL RDS instance"
  type        = string
  default     = "db.t3.medium"
}

variable "postgresql_allocated_storage" {
  description = "Allocated storage for the PostgreSQL RDS instance (in GB)"
  type        = number
  default     = 20
}

variable "postgresql_max_allocated_storage" {
  description = "Maximum allocated storage for the PostgreSQL RDS instance (in GB)"
  type        = number
  default     = 100
}

variable "postgresql_db_name" {
  description = "Name of the PostgreSQL database"
  type        = string
  default     = "postgres"
}

variable "postgresql_username" {
  description = "Master username for the PostgreSQL RDS instance"
  type        = string
  default     = "postgres"
}

variable "postgresql_skip_final_snapshot" {
  description = "Whether to skip the final snapshot when deleting the PostgreSQL RDS instance. Ignored for an instance built as a read replica, which AWS never snapshots on delete."
  type        = bool
  default     = false
}

variable "postgresql_final_snapshot_identifier" {
  description = "Suffix for the final snapshot of each PostgreSQL RDS instance, required when skip_final_snapshot is false. Each instance prefixes its own name, so the deployment's snapshots do not collide with one another."
  type        = string
  default     = "final-snapshot"
}

variable "postgresql_deletion_protection" {
  description = "Whether to enable deletion protection for the PostgreSQL RDS instance"
  type        = bool
  default     = true
}

variable "postgresql_backup_retention_period" {
  description = "Backup retention period for the PostgreSQL RDS instance (in days)"
  type        = number
  default     = 7
}

variable "postgresql_backup_window" {
  description = "Preferred backup window for the PostgreSQL RDS instance"
  type        = string
  default     = "03:00-04:00"
}

variable "postgresql_maintenance_window" {
  description = "Preferred maintenance window for the PostgreSQL RDS instance"
  type        = string
  default     = "sun:04:00-sun:05:00"
}

variable "postgresql_multi_az" {
  description = "Whether to enable Multi-AZ deployment for the PostgreSQL RDS instance"
  type        = bool
  default     = true
}

# Scheduler RDS - Multiple instances support
variable "scheduler_postgresql_instances" {
  description = <<-EOT
    Names of the dedicated PostgreSQL instances to build for the Dapr scheduler, one instance per entry.

    Empty by default, because the chart's scheduler default does not use them: agent.config.internal_dapr.scheduler.postgresql.use_global is true, which keeps the scheduler's jobs and actor reminders in a `sched` database on the managed state store — the instance aws_db_instance.postgresql builds. A non-empty list here with that default in place builds instances nothing ever connects to.

    Set it only together with use_global: false and the chart's scheduler.postgresql.connections, which is the dedicated-database layout charts/guides/production/README.md describes. A member of a Catalyst region group must leave it empty: the group's safety rests on one replicated database with one writer, and a dedicated scheduler instance adds a second of each.

    UPGRADE NOTE: this defaulted to ["pg1"] until the default was corrected to match the chart. A deployment that relied on the old default and pointed the chart at the instance it built (use_global: false) must set this variable explicitly to keep it — otherwise the next apply destroys that instance, and with it the scheduler's jobs and actor reminders. A deployment that left the chart on its default is not using the instance and loses nothing.
  EOT
  type        = list(string)
  default     = []
}

variable "postgresql_scheduler_instance_class" {
  description = "Instance class for all Scheduler PostgreSQL RDS instances"
  type        = string
  default     = "db.t3.medium"
}

variable "postgresql_scheduler_db_name" {
  description = "Database name for all Scheduler PostgreSQL RDS instances"
  type        = string
  default     = "scheduler"
}

variable "postgresql_scheduler_username" {
  description = "Master username for all Scheduler PostgreSQL RDS instances"
  type        = string
  default     = "postgres"
}

# Two-region variables
#
# All of these default to the single-region behaviour this guide has always had.
# Set them only when the region is a member of a Catalyst region group. The
# guide that uses them is the AWS multi-region deployment page:
# https://docs.diagrid.io/operate/hosting/enterprise-self-hosted/aws-multi-region-deployment

variable "postgresql_manage_master_user_password" {
  description = "Let RDS manage the master password in Secrets Manager. Must be false on both regions of a two-region deployment: RDS refuses to create a read replica of a source whose credentials it manages."
  type        = bool
  default     = true
}

variable "postgresql_password" {
  description = "Master password for the PostgreSQL RDS instances, used when postgresql_manage_master_user_password is false"
  type        = string
  default     = null
  sensitive   = true
}

variable "postgresql_replicate_source_db_arn" {
  description = "ARN of the shared PostgreSQL instance in the other region. When set, this region's shared PostgreSQL is created as a cross-region read replica of it instead of as a writer, and the region is the passive member of its group. Clear it and apply to promote."
  type        = string
  default     = ""
}

variable "scheduler_postgresql_replicate_source_db_arns" {
  description = "ARNs of the scheduler PostgreSQL instances in the other region, keyed by the scheduler_postgresql_instances entry they replicate. Same promotion semantics as postgresql_replicate_source_db_arn. A region group's members are expected to run the Dapr scheduler on the shared database instead (scheduler_postgresql_instances = [] and the chart's default agent.config.internal_dapr.scheduler.postgresql.use_global = true), which leaves one replication stream and one writer for the group to reason about; set this only for a group that keeps separate scheduler instances anyway."
  type        = map(string)
  default     = {}
}

variable "route53_zone_id" {
  description = "ID of an existing Route 53 hosted zone to put this region's records in. Empty creates a zone for region_ingress_endpoint, which is this guide's single-region behaviour. The second region of a group sets this to the zone the first region created, so both regions share one wildcard domain."
  type        = string
  default     = ""
}

variable "region_group_member" {
  description = "This region is a member of a Catalyst region group. A group's two regions serve the same wildcard domain, so neither of them owns that domain's record: the group's front door does, and the region-group stack creates it. Both regions of a group set this to true."
  type        = bool
  default     = false
}

variable "kek_kms_enabled" {
  description = "Create an AWS KMS key for the Catalyst secrets provider's envelope encryption, and the role the agent and management service assume to use it. A region group needs every member to resolve the same key; leave it off for a single region, which has nothing to share a key with."
  type        = bool
  default     = false
}

variable "kek_kms_replica_source_key_arn" {
  description = "ARN of the other region's KEK. Empty creates a new multi-region primary key, which is what the first region of a group does. Set it to the first region's kek_kms_key_arn output and this region creates a replica of that key instead: the same key identity, its own ARN, in its own region. Ignored when kek_kms_enabled is false."
  type        = string
  default     = ""
}

variable "kek_kms_service_account_subjects" {
  description = "Kubernetes service accounts allowed to assume the KEK role, as OIDC subjects. The defaults are what the Catalyst chart creates for a release named `catalyst` in the `cra-agent` namespace; change them if you install under another release name or namespace."
  type        = list(string)
  default = [
    "system:serviceaccount:cra-agent:catalyst-agent-sa",
    "system:serviceaccount:cra-agent:catalyst-management-sa",
  ]
}
