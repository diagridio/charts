variable "subscription_id" {
  description = "Azure subscription the region is built in. Null falls through to the ARM_SUBSCRIPTION_ID environment variable, which `az account set` and the provider both use."
  type        = string
  default     = null
}

variable "tenant_id" {
  description = "Azure AD tenant the subscription belongs to"
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region for all resources, e.g. westus2"
  type        = string
  default     = "westus2"
}

variable "tags" {
  description = "Tags to apply to all Azure resources"
  type        = map(string)
  default     = {}
}

variable "cluster_name" {
  description = "Name of the AKS cluster. It also prefixes every other resource this root creates, and names this region within its group."
  type        = string
  default     = "catalyst"
}

variable "resource_group_name" {
  description = "Resource group to create for this region. Empty names it after the cluster."
  type        = string
  default     = ""
}

# AKS retires a minor version from community support about a year after it is
# released, and from then on will only create a cluster on it if the cluster is
# enrolled in Long-Term Support. A create on a demoted version fails outright
# with K8sVersionNotSupported, so this default has a shelf life. Check what the
# regions you are deploying into currently offer, and give both members of a
# region group the same version:
#
#   az aks get-versions -l <region> -o table
#
# Prefer a version listed as KubernetesOfficial over one listed only as
# AKSLongTermSupport. The newest version Azure offers is not always the safest
# choice for a group: new minors reach regions at different times, so a version
# available in one member's region may not yet exist in the other's.
variable "cluster_version" {
  description = "Kubernetes version for the AKS cluster. Must be a version AKS still offers outside Long-Term Support in both regions - see az aks get-versions."
  type        = string
  default     = "1.34"
}

variable "region_ingress_endpoint" {
  description = "Catalyst regional ingress endpoint"
  type        = string
  default     = null
}

variable "vnet_cidr" {
  description = "CIDR block for the virtual network. The two regions of a group must use ranges that do not overlap, subnets included: Azure peers them for the database's cross-region replication and refuses to peer overlapping address spaces. The second region of a group therefore overrides this and the three subnet CIDRs."
  type        = string
  default     = "10.0.0.0/16"
}

variable "aks_subnet_cidr" {
  description = "CIDR block for the AKS node subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "database_subnet_cidr" {
  description = "CIDR block for the PostgreSQL delegated subnet. Flexible Server takes exclusive use of the subnet it is delegated, so nothing else can be placed here."
  type        = string
  default     = "10.0.2.0/24"
}

variable "bastion_subnet_cidr" {
  description = "CIDR block for the bastion subnet"
  type        = string
  default     = "10.0.3.0/24"
}

variable "availability_zones" {
  description = "Availability zones to spread the worker nodes and the region's public address across. Not every Azure region has zones, and a region that has none refuses a zonal resource — set this to [] there, and postgresql_high_availability to false with it."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "service_cidr" {
  description = "CIDR the cluster allocates Kubernetes Service addresses from. It must not overlap vnet_cidr: with Azure CNI the pods take virtual network addresses, and AKS refuses a service range that collides with them. AKS's own default is 10.0.0.0/16, which is this guide's default virtual network — hence a value here rather than none."
  type        = string
  default     = "172.16.0.0/16"
}

variable "dns_service_ip" {
  description = "Address of the cluster's DNS service. Must be inside service_cidr."
  type        = string
  default     = "172.16.0.10"
}

variable "enable_peering" {
  description = "Whether to peer this region's virtual network with an external one"
  type        = bool
  default     = false
}

variable "peer_vnet_id" {
  description = "Resource ID of the external virtual network to peer with"
  type        = string
  default     = ""
}

variable "node_instance_type" {
  description = "Virtual machine size for the AKS worker nodes"
  type        = string
  default     = "Standard_D4s_v5"
}

variable "node_min_capacity" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 2
}

variable "node_max_capacity" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 5
}

variable "node_desired_capacity" {
  description = "Number of worker nodes at launch"
  type        = number
  default     = 2
}

variable "enable_bastion" {
  description = "Whether to deploy a jumpbox for cluster access. The AKS API server is reachable publicly by default, so this is off unless you restrict it."
  type        = bool
  default     = false
}

variable "bastion_instance_type" {
  description = "Virtual machine size for the bastion host"
  type        = string
  default     = "Standard_B2s"
}

variable "bastion_admin_username" {
  description = "Administrator username on the bastion host"
  type        = string
  default     = "azureuser"
}

variable "bastion_ssh_public_key" {
  description = "SSH public key authorised on the bastion host. Required when enable_bastion is true; Azure Linux VMs have no password login."
  type        = string
  default     = ""
}

variable "bastion_allowed_cidr" {
  description = "CIDR block allowed to SSH to the bastion host"
  type        = string
  default     = "0.0.0.0/0" # Should be restricted in production
}

variable "api_server_authorized_ip_ranges" {
  description = "CIDR blocks allowed to reach the AKS API server. Empty leaves it open to the internet, which is AKS's own default. The cluster's API server is public in this guide whether or not a bastion is deployed: the bastion exists to reach the PostgreSQL servers, which are injected into the virtual network and have no public endpoint at all."
  type        = list(string)
  default     = []
}

variable "aks_admin_principal_ids" {
  description = "Object IDs of Entra ID users, groups or service principals to grant cluster-admin on the AKS cluster"
  type        = list(string)
  default     = []
}

variable "aks_readonly_principal_ids" {
  description = "Object IDs of Entra ID users, groups or service principals to grant read-only access to the AKS cluster"
  type        = list(string)
  default     = []
}

# PostgreSQL Flexible Server Variables
variable "postgresql_version" {
  description = "PostgreSQL engine version. A region group's passive member needs 16 or later: its scheduler runs logical decoding against a read replica, and a standby cannot decode before 16."
  type        = string
  default     = "17"

  # The Dapr scheduler reaches its database over a logical replication
  # connection. In a single region that database is a writer, which decodes on
  # any supported engine. A group's passive member points
  # postgresql_replicate_source_server_id at the other region and runs the same
  # scheduler against a standby, and logical decoding on a standby arrived in
  # PostgreSQL 16 - so a group pinned below it has a passive region whose
  # scheduler never starts, three pods deep in a namespace the guide never
  # asks anyone to look at. Fail at plan time instead.
  validation {
    condition     = var.postgresql_replicate_source_server_id == "" || tonumber(var.postgresql_version) >= 16
    error_message = "A region group's passive member needs postgresql_version 16 or later; logical decoding on a read replica is not available before it."
  }
}

variable "postgresql_instance_class" {
  description = "SKU name for the shared PostgreSQL Flexible Server, in Azure's <tier>_<VM size> form, e.g. GP_Standard_D2ds_v5"
  type        = string
  default     = "GP_Standard_D2ds_v5"
}

variable "postgresql_allocated_storage" {
  description = "Storage for the PostgreSQL Flexible Server, in GiB. Flexible Server only accepts its own fixed steps (32, 64, 128, 256, ...), and storage can be grown but never shrunk."
  type        = number
  default     = 32
}

variable "postgresql_auto_grow_enabled" {
  description = "Let Flexible Server grow its own storage as it fills. Azure's equivalent of the AWS guide's postgresql_max_allocated_storage, which has no ceiling to set: it steps the disk up when free space runs low and there is no upper bound to configure."
  type        = bool
  default     = true
}

variable "postgresql_db_name" {
  description = "Name of the PostgreSQL database Catalyst keeps its state in. Not `postgres`: every Flexible Server is created with a `postgres` database of its own, and a second one under that name cannot be created."
  type        = string
  default     = "catalyst"

  validation {
    condition     = !contains(["postgres", "azure_maintenance", "azure_sys"], var.postgresql_db_name)
    error_message = "postgresql_db_name cannot be one of Flexible Server's own databases (postgres, azure_maintenance, azure_sys). Pick another name — the guide's default is `catalyst`."
  }
}

variable "postgresql_username" {
  description = "Administrator username for the PostgreSQL Flexible Server"
  type        = string
  default     = "postgres"
}

variable "postgresql_password" {
  description = "Administrator password for the PostgreSQL Flexible Servers"
  type        = string
  sensitive   = true
}

variable "postgresql_backup_retention_period" {
  description = "Backup retention period for the PostgreSQL Flexible Server (in days)"
  type        = number
  default     = 7
}

variable "postgresql_geo_redundant_backup_enabled" {
  description = "Keep backups in the paired Azure region as well as this one"
  type        = bool
  default     = false
}

variable "postgresql_high_availability" {
  description = "Run the PostgreSQL Flexible Server with a zone-redundant standby. Azure's equivalent of the AWS guide's postgresql_multi_az. Not offered in every region, not available on a Burstable SKU, and not possible on a read replica, so the region that joins a group sets it false - see the comment on the high_availability block in postgresql.tf for how to check before you apply."
  type        = bool
  default     = true
}

variable "postgresql_maintenance_window" {
  description = "Weekly window Azure may patch the servers in, as day_of_week (0 = Sunday), start_hour and start_minute in UTC"
  type = object({
    day_of_week  = number
    start_hour   = number
    start_minute = number
  })
  default = {
    day_of_week  = 0
    start_hour   = 4
    start_minute = 0
  }
}

# Scheduler PostgreSQL - Multiple instances support
variable "scheduler_postgresql_instances" {
  description = <<-EOT
    Names of the dedicated PostgreSQL Flexible Servers to build for the Dapr scheduler, one server per entry.

    Empty by default, because the chart's scheduler default does not use them: agent.config.internal_dapr.scheduler.postgresql.use_global is true, which keeps the scheduler's jobs and actor reminders in a `sched` database on the managed state store — the server azurerm_postgresql_flexible_server.postgresql builds. A non-empty list here with that default in place builds servers nothing ever connects to.

    Set it only together with use_global: false and the chart's scheduler.postgresql.connections, which is the dedicated-database layout charts/guides/production/README.md describes. A member of a Catalyst region group must leave it empty: the group's safety rests on one replicated database with one writer, and a dedicated scheduler server adds a second of each.
  EOT
  type        = list(string)
  default     = []
}

variable "postgresql_scheduler_instance_class" {
  description = "SKU name for all scheduler PostgreSQL Flexible Servers"
  type        = string
  default     = "GP_Standard_D2ds_v5"
}

variable "postgresql_scheduler_db_name" {
  description = "Database name for all scheduler PostgreSQL Flexible Servers. Same restriction as postgresql_db_name."
  type        = string
  default     = "scheduler"

  validation {
    condition     = !contains(["postgres", "azure_maintenance", "azure_sys"], var.postgresql_scheduler_db_name)
    error_message = "postgresql_scheduler_db_name cannot be one of Flexible Server's own databases (postgres, azure_maintenance, azure_sys)."
  }
}

variable "postgresql_scheduler_username" {
  description = "Administrator username for all scheduler PostgreSQL Flexible Servers"
  type        = string
  default     = "postgres"
}

# Two-region variables
#
# All of these default to the single-region behaviour this guide has always had.
# Set them only when the region is a member of a Catalyst region group. The
# guide that uses them is the Azure multi-region deployment page:
# https://docs.diagrid.io/operate/hosting/enterprise-self-hosted/azure-multi-region-deployment

variable "postgresql_replicate_source_server_id" {
  description = <<-EOT
    Resource ID of the shared PostgreSQL Flexible Server in the other region. When set, this region's shared PostgreSQL is created as a cross-region read replica of it instead of as a writer, and the region is the passive member of its group.

    LEAVE IT SET AFTER A FAILOVER. Unlike the AWS guide's postgresql_replicate_source_db_arn, this is not what you clear to promote — `source_server_id` forces a new server, so clearing it DESTROYS the database you just failed over to. Promotion is postgresql_promote_replica below, which leaves this variable exactly where it is.
  EOT
  type        = string
  default     = ""
}

variable "postgresql_promote_replica" {
  description = <<-EOT
    Promote this region's shared PostgreSQL read replica to a standalone writer. This is the failover step.

    Azure promotes a replica in place, by setting `replication_role = "None"` on a server that keeps its Replica create mode and its source server id. So a promoted region's configuration keeps postgresql_replicate_source_server_id pointing at what used to be its source — that is what a promoted server looks like, not leftover state, and clearing it destroys the server.

    Promotion is one-way. A server that has been promoted cannot be made to follow again; failing back rebuilds it as a fresh replica, which is what ./failover.sh follow does.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.postgresql_promote_replica || var.postgresql_replicate_source_server_id != ""
    error_message = "postgresql_promote_replica needs postgresql_replicate_source_server_id to stay set: Azure promotes a replica in place and keeps its source server id. Clearing it would destroy the server instead of promoting it."
  }
}

variable "scheduler_postgresql_replicate_source_server_ids" {
  description = "Resource IDs of the scheduler PostgreSQL Flexible Servers in the other region, keyed by the scheduler_postgresql_instances entry they replicate. Same semantics as postgresql_replicate_source_server_id, including that they stay set after a promotion. A region group's members are expected to run the Dapr scheduler on the shared database instead (scheduler_postgresql_instances = [] and the chart's default agent.config.internal_dapr.scheduler.postgresql.use_global = true), which leaves one replication stream and one writer for the group to reason about; set this only for a group that keeps separate scheduler servers anyway."
  type        = map(string)
  default     = {}
}

variable "scheduler_postgresql_promote_replicas" {
  description = "Promote this region's scheduler PostgreSQL read replicas, keyed by the scheduler_postgresql_instances entry. Same semantics as postgresql_promote_replica. An entry left out is false."
  type        = map(bool)
  default     = {}
}

variable "dns_zone_resource_group_name" {
  description = "Resource group of an existing public DNS zone to put this region's records in. Empty creates a zone for region_ingress_endpoint in this region's own resource group, which is this guide's single-region behaviour. The second region of a group sets this to the first region's resource_group_name, so both regions share one wildcard domain.\n\nAzure addresses a DNS record by zone NAME and resource group rather than by zone id, and the zone's name is region_ingress_endpoint — which both regions of a group are applied with already. So the resource group is the only thing the second region needs to be told, and this is the counterpart of the AWS guide's route53_zone_id."
  type        = string
  default     = ""
}

variable "region_group_peer_vnet_id" {
  description = "The other group member's vnet_id output. Set it in the region that joins the group — the one whose database is built as a replica — and only there: that region then creates both halves of the peering between the two networks, and both private DNS links, which a cross-region replica of a VNet-integrated server cannot be created without. Leave it set for the group's lifetime, including after a failover."
  type        = string
  default     = ""

  validation {
    condition     = var.region_group_peer_vnet_id == "" || can(regex("/providers/Microsoft.Network/virtualNetworks/[^/]+-vnet$", var.region_group_peer_vnet_id))
    error_message = "region_group_peer_vnet_id must be the other region's vnet_id output: a virtual network this stack built, named \"<cluster>-vnet\"."
  }
}

variable "region_group_member" {
  description = "This region is a member of a Catalyst region group. A group's two regions serve the same wildcard domain, so neither of them owns that domain's record: the group's front door does, and the region-group stack creates it. Both regions of a group set this to true."
  type        = bool
  default     = false
}
