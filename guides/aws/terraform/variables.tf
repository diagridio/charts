variable "aws_region" {
  description = "AWS region for all resources"
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  default     = "catalyst"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  default     = "1.32"
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
  description = "PostgreSQL engine version"
  type        = string
  default     = "17.5"
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
  description = "Whether to skip the final snapshot when deleting the PostgreSQL RDS instance"
  type        = bool
  default     = false
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
