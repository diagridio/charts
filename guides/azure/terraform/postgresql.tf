# PostgreSQL Flexible Server configuration

# Flexible Server with private networking resolves through a private DNS zone,
# and the zone has to exist before the server is created. The name is prefixed
# with the cluster so that the two regions of a group, which each create their
# own, stay distinguishable in a subscription that holds both.
resource "azurerm_private_dns_zone" "postgresql" {
  name                = "${var.cluster_name}.private.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgresql" {
  name                 = "${var.cluster_name}-postgresql"
  private_dns_zone_id  = azurerm_private_dns_zone.postgresql.id
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = false
  tags                 = var.tags
}

locals {
  # A passive region points postgresql_replicate_source_server_id at the active
  # region's server and gets a read replica instead of a writer.
  postgresql_is_replica = var.postgresql_replicate_source_server_id != ""

  # Flexible Server takes storage in MiB, and only in its own fixed steps.
  postgresql_storage_mb = var.postgresql_allocated_storage * 1024
}

# The shared PostgreSQL Flexible Server.
#
# How this region becomes a replica, and how it stops being one, is the whole
# of the two-region story and it does not work the way the AWS guide's does.
#
# On AWS a replica is promoted by CLEARING its replication source. Here that
# would be a catastrophe: `source_server_id` forces a new server, so clearing it
# destroys the database rather than promoting it. Azure promotes in place, with
# a PATCH that sets `replication_role = "None"` on a server that keeps both its
# Replica create mode and its source server id — which is why
# postgresql_promote_replica is a variable of its own and why
# postgresql_replicate_source_server_id stays set for the life of the server.
#
# `replication_role` cannot be set when the server is created, only updated
# afterwards, and only ever to "None". So a region cannot be built pre-promoted:
# it is created as a replica and promoted by a second apply, which is exactly
# the failover step.
#
# Promotion is one-way. Azure has no demote, so failing back rebuilds the server
# as a fresh replica — ./failover.sh follow, which destroys it first.
resource "azurerm_postgresql_flexible_server" "postgresql" {
  name                = "${var.cluster_name}-postgresql"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  create_mode      = local.postgresql_is_replica ? "Replica" : null
  source_server_id = local.postgresql_is_replica ? var.postgresql_replicate_source_server_id : null
  replication_role = var.postgresql_promote_replica ? "None" : null

  # A replica inherits the administrator from the server it follows, and Azure
  # refuses both fields outright when create_mode is Replica.
  administrator_login    = local.postgresql_is_replica ? null : var.postgresql_username
  administrator_password = local.postgresql_is_replica ? null : var.postgresql_password

  version    = var.postgresql_version
  sku_name   = var.postgresql_instance_class
  storage_mb = local.postgresql_storage_mb
  # Flexible Server grows storage on its own and has no ceiling to configure,
  # unlike the AWS guide's postgresql_max_allocated_storage. Storage can never
  # be shrunk: reducing postgresql_allocated_storage plans a REPLACEMENT.
  auto_grow_enabled = var.postgresql_auto_grow_enabled

  delegated_subnet_id = azurerm_subnet.database.id
  private_dns_zone_id = azurerm_private_dns_zone.postgresql.id
  # The server is reached over the virtual network only. The bastion is how a
  # person reaches it; nothing reaches it from the internet.
  public_network_access_enabled = false

  backup_retention_days        = var.postgresql_backup_retention_period
  geo_redundant_backup_enabled = var.postgresql_geo_redundant_backup_enabled

  # Zone-redundant high availability, Azure's counterpart to RDS multi-AZ. It
  # needs a General Purpose or Memory Optimized SKU — a Burstable one (B_...)
  # cannot do it — and it is not offered in every region.
  #
  # Check before you apply, because a region that does not offer it fails the
  # create outright, after several minutes, with "HA is disabled for region
  # <region>":
  #
  #   az postgres flexible-server list-skus -l <region> \
  #     --query "[0].supportedServerEditions[?name=='GeneralPurpose'].supportedServerSkus[].supportedHaMode" -o tsv
  #
  # ZoneRedundant has to appear there. If it does not, apply that region with
  # postgresql_high_availability = false. Availability is per region and per
  # subscription, so the two members of a region group can differ — and it is
  # the region holding the WRITER that fails first, because it is built first.
  #
  # A read replica cannot have it at all. Azure does not refuse the create — it
  # leaves the replica in "Updating" until the provider's timeout — so the
  # precondition in the lifecycle block below refuses it at plan time instead.
  # A replica is applied with postgresql_high_availability = false; turn it on
  # after the region has been promoted, as a separate in-place update rather
  # than in the promotion's own apply.
  dynamic "high_availability" {
    for_each = var.postgresql_high_availability ? [1] : []

    content {
      mode = "ZoneRedundant"
    }
  }

  maintenance_window {
    day_of_week  = var.postgresql_maintenance_window.day_of_week
    start_hour   = var.postgresql_maintenance_window.start_hour
    start_minute = var.postgresql_maintenance_window.start_minute
  }

  tags = var.tags

  # Azure picks the availability zone at create when the configuration does not
  # name one, and picks the standby's zone the same way when high availability
  # is on. The provider records both and then, on the NEXT plan, proposes to
  # unset them because the configuration is silent — which Azure refuses:
  #
  #   Error: `zone` can only be changed when exchanged with the zone specified
  #   in `high_availability.0.standby_availability_zone`
  #
  # Without this the stack does not converge: the first apply succeeds and
  # every apply after it fails, including the ones ./failover.sh runs to move
  # the writer. Ignoring them is right rather than merely expedient — the zone
  # of a server that already exists is not something this stack ever chooses.
  lifecycle {
    ignore_changes = [
      zone,
      high_availability[0].standby_availability_zone,
    ]

    precondition {
      condition     = !(local.postgresql_is_replica && !var.postgresql_promote_replica && var.postgresql_high_availability)
      error_message = "A read replica cannot have high availability: set postgresql_high_availability = false for this region. Azure does not refuse it — the create hangs until it times out. Turn it back on after the region has been promoted, in an apply of its own."
    }
  }

  # A replica of a server in another region cannot be created before the two
  # networks are peered and each can resolve the other's database name.
  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.postgresql,
    azurerm_virtual_network_peering.region_group_to_peer,
    azurerm_virtual_network_peering.region_group_from_peer,
    azurerm_private_dns_zone_virtual_network_link.postgresql_region_group_peer,
    azurerm_private_dns_zone_virtual_network_link.postgresql_region_group_peer_zone,
  ]
}

# A replica carries the source server's databases, so creating one here would
# collide with what replication already delivered.
resource "azurerm_postgresql_flexible_server_database" "postgresql" {
  count = local.postgresql_is_replica ? 0 : 1

  name      = var.postgresql_db_name
  server_id = azurerm_postgresql_flexible_server.postgresql.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# The Dapr scheduler opens a logical replication connection to its database, and
# by default that database is this one: the chart's scheduler default is
# backend_type: postgresql with postgresql.use_global: true, which puts the
# scheduler's jobs and actor reminders in a `sched` database on the managed
# state store rather than on a server of its own. A region group's members are
# required to run it that way (scheduler_postgresql_instances = []), so for them
# this is not optional.
#
# Without it wal_level stays `replica` and every scheduler replica crash-loops,
# which costs the region all jobs and actor reminders.
#
# wal_level is static, so Azure restarts the server when this changes. Set on
# the writer only: a read replica takes its WAL level from the WAL stream it is
# replaying, and Azure refuses to configure one independently. That is also why
# a group's passive region can decode at all — the setting it needs is one the
# active region made.
resource "azurerm_postgresql_flexible_server_configuration" "wal_level" {
  count = local.postgresql_is_replica ? 0 : 1

  name      = "wal_level"
  server_id = azurerm_postgresql_flexible_server.postgresql.id
  value     = "logical"
}

output "postgresql_endpoint" {
  description = "The connection endpoint for the shared PostgreSQL Flexible Server"
  value       = azurerm_postgresql_flexible_server.postgresql.fqdn
}

output "postgresql_port" {
  description = "The port for the shared PostgreSQL Flexible Server"
  value       = 5432
}

output "postgresql_database_name" {
  description = "The database name on the shared PostgreSQL Flexible Server"
  value       = var.postgresql_db_name
}

output "postgresql_username" {
  description = "The administrator username for the shared PostgreSQL Flexible Server. A replica inherits the one the server it follows was created with."
  value       = var.postgresql_username
}

output "postgresql_server_id" {
  description = "Resource ID of the shared PostgreSQL Flexible Server. Feed this to the other region's postgresql_replicate_source_server_id to make its shared PostgreSQL a read replica of this one."
  value       = azurerm_postgresql_flexible_server.postgresql.id
}

output "postgresql_replication_role" {
  description = "Whether this region's shared PostgreSQL is following another. Empty on a server that was never a replica; `None` on one that was promoted."
  value       = azurerm_postgresql_flexible_server.postgresql.replication_role
}

# Scheduler PostgreSQL Flexible Server configuration

locals {
  # Replication source per scheduler server, empty for the ones this region
  # writes.
  scheduler_replicate_source_server_ids = {
    for k in var.scheduler_postgresql_instances :
    k => lookup(var.scheduler_postgresql_replicate_source_server_ids, k, "")
  }

  scheduler_promote_replicas = {
    for k in var.scheduler_postgresql_instances :
    k => lookup(var.scheduler_postgresql_promote_replicas, k, false)
  }
}

resource "azurerm_private_dns_zone" "scheduler_postgresql" {
  for_each = toset(var.scheduler_postgresql_instances)

  name                = "${var.cluster_name}-scheduler-${each.key}.private.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "scheduler_postgresql" {
  for_each = toset(var.scheduler_postgresql_instances)

  name                 = "${var.cluster_name}-scheduler-${each.key}"
  private_dns_zone_id  = azurerm_private_dns_zone.scheduler_postgresql[each.key].id
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = false
  tags                 = var.tags
}

# Per scheduler server, for the same reasons as the shared one above.
resource "azurerm_postgresql_flexible_server" "scheduler_postgresql" {
  for_each = toset(var.scheduler_postgresql_instances)

  name                = "${var.cluster_name}-scheduler-${each.key}-postgresql"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  create_mode      = local.scheduler_replicate_source_server_ids[each.key] != "" ? "Replica" : null
  source_server_id = local.scheduler_replicate_source_server_ids[each.key] != "" ? local.scheduler_replicate_source_server_ids[each.key] : null
  replication_role = local.scheduler_promote_replicas[each.key] ? "None" : null

  administrator_login    = local.scheduler_replicate_source_server_ids[each.key] != "" ? null : var.postgresql_scheduler_username
  administrator_password = local.scheduler_replicate_source_server_ids[each.key] != "" ? null : var.postgresql_password

  version           = var.postgresql_version
  sku_name          = var.postgresql_scheduler_instance_class
  storage_mb        = local.postgresql_storage_mb
  auto_grow_enabled = var.postgresql_auto_grow_enabled

  delegated_subnet_id           = azurerm_subnet.database.id
  private_dns_zone_id           = azurerm_private_dns_zone.scheduler_postgresql[each.key].id
  public_network_access_enabled = false

  backup_retention_days        = var.postgresql_backup_retention_period
  geo_redundant_backup_enabled = var.postgresql_geo_redundant_backup_enabled

  maintenance_window {
    day_of_week  = var.postgresql_maintenance_window.day_of_week
    start_hour   = var.postgresql_maintenance_window.start_hour
    start_minute = var.postgresql_maintenance_window.start_minute
  }

  tags = var.tags

  depends_on = [azurerm_private_dns_zone_virtual_network_link.scheduler_postgresql]
}

resource "azurerm_postgresql_flexible_server_database" "scheduler_postgresql" {
  for_each = toset([
    for k in var.scheduler_postgresql_instances :
    k if local.scheduler_replicate_source_server_ids[k] == ""
  ])

  name      = var.postgresql_scheduler_db_name
  server_id = azurerm_postgresql_flexible_server.scheduler_postgresql[each.key].id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_postgresql_flexible_server_configuration" "scheduler_wal_level" {
  for_each = toset([
    for k in var.scheduler_postgresql_instances :
    k if local.scheduler_replicate_source_server_ids[k] == ""
  ])

  name      = "wal_level"
  server_id = azurerm_postgresql_flexible_server.scheduler_postgresql[each.key].id
  value     = "logical"
}

output "scheduler_postgresql_endpoints" {
  description = "Map of connection endpoints for all scheduler PostgreSQL Flexible Servers"
  value       = { for k, v in azurerm_postgresql_flexible_server.scheduler_postgresql : k => v.fqdn }
}

output "scheduler_postgresql_database_names" {
  description = "Map of database names for all scheduler PostgreSQL Flexible Servers"
  value       = { for k in var.scheduler_postgresql_instances : k => var.postgresql_scheduler_db_name }
}

output "scheduler_postgresql_server_ids" {
  description = "Map of resource IDs for all scheduler PostgreSQL Flexible Servers. Feed this to the other region's scheduler_postgresql_replicate_source_server_ids to make its scheduler servers read replicas of these."
  value       = { for k, v in azurerm_postgresql_flexible_server.scheduler_postgresql : k => v.id }
}
