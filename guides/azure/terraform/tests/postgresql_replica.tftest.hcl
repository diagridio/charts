# How the passive region's PostgreSQL servers are built, and — the part that
# matters — what promoting one looks like.
#
# Azure promotes a replica in place, with a PATCH setting replication_role to
# None on a server that KEEPS its Replica create mode and its source server id.
# The AWS guide's shape, clearing the replication source to promote, destroys
# the database here: source_server_id forces a new server. These runs pin the
# difference down, because a configuration that drifts back towards the AWS
# spelling would plan a replacement of the database the group has just failed
# over to.
#
# Run with: terraform test

mock_provider "azurerm" {}

# plan rather than apply throughout. Several of the attributes these runs assert
# on — administrator_login among them — are Optional and Computed, so an applied
# run leaves a value behind that the next run inherits where its own
# configuration says null. Planning each run from no state is what makes each
# one an assertion about its own configuration.

# A mocked resource gets a random string for every attribute, and azurerm
# validates a resource id it is handed. These give the ids that are consumed by
# another resource the shape the provider parses.
override_resource {
  target          = azurerm_virtual_network.this
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-rg/providers/Microsoft.Network/virtualNetworks/catalyst-vnet"
  }
}

override_resource {
  target          = azurerm_subnet.aks
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-rg/providers/Microsoft.Network/virtualNetworks/catalyst-vnet/subnets/catalyst-aks-subnet"
  }
}

override_resource {
  target          = azurerm_subnet.database
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-rg/providers/Microsoft.Network/virtualNetworks/catalyst-vnet/subnets/catalyst-db-subnet"
  }
}

override_resource {
  target          = azurerm_network_security_group.aks
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-rg/providers/Microsoft.Network/networkSecurityGroups/catalyst-aks-nsg"
  }
}

override_resource {
  target          = azurerm_private_dns_zone.postgresql
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-rg/providers/Microsoft.Network/privateDnsZones/catalyst.private.postgres.database.azure.com"
  }
}

override_resource {
  target          = azurerm_private_dns_zone.scheduler_postgresql
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-rg/providers/Microsoft.Network/privateDnsZones/catalyst-scheduler-pg1.private.postgres.database.azure.com"
  }
}

override_resource {
  target          = azurerm_public_ip.gateway
  override_during = plan
  values = {
    id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-rg/providers/Microsoft.Network/publicIPAddresses/catalyst-gateway-pip"
    ip_address = "198.51.100.10"
  }
}

override_resource {
  target          = azurerm_kubernetes_cluster.this
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-rg/providers/Microsoft.ContainerService/managedClusters/catalyst"
  }
}

override_resource {
  target          = azurerm_postgresql_flexible_server.postgresql
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/catalyst-postgresql"
  }
}

override_resource {
  target          = azurerm_postgresql_flexible_server.scheduler_postgresql
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/catalyst-scheduler-pg1-postgresql"
  }
}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  tenant_id               = "11111111-1111-1111-1111-111111111111"
  region_ingress_endpoint = "catalyst.example.com"
  postgresql_password     = "not-a-real-password"
  enable_bastion          = false
  enable_peering          = false
  region_group_member     = false

  scheduler_postgresql_instances = ["pg1"]
}

# The active region writes. It is a replica of nothing, it creates its own
# databases, and it is the one that sets the WAL level the group's replication
# depends on.
run "the_writing_region_is_a_replica_of_nothing" {
  command = plan

  variables {
    cluster_name                                     = "catalyst-west"
    postgresql_replicate_source_server_id            = ""
    scheduler_postgresql_replicate_source_server_ids = {}
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.postgresql.create_mode == null && azurerm_postgresql_flexible_server.postgresql.source_server_id == null
    error_message = "a region given no replication source writes; it is not a replica of anything"
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.postgresql.replication_role == null
    error_message = "a server that was never a replica has no replication role to clear"
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.postgresql.administrator_login == "postgres"
    error_message = "the writer is created with its own administrator; only a replica inherits one"
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server_database.postgresql) == 1
    error_message = "the writing region creates the database; a replica receives it through replication instead"
  }

  # wal_level is what lets the passive region's scheduler decode at all, and it
  # is a setting only the writer can make — a replica takes its WAL level from
  # the stream it replays.
  assert {
    condition     = one(azurerm_postgresql_flexible_server_configuration.wal_level).value == "logical"
    error_message = "without logical WAL the passive region's scheduler never starts, and the region loses every job and actor reminder"
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.scheduler_postgresql["pg1"].create_mode == null
    error_message = "the scheduler servers follow the shared one"
  }
}

# The passive region's servers are replicas. Azure refuses an administrator on
# one outright, and the databases arrive through replication.
run "the_passive_region_follows_and_inherits" {
  command = plan

  variables {
    cluster_name                          = "catalyst-east"
    postgresql_high_availability          = false
    postgresql_replicate_source_server_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-west-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/catalyst-west-postgresql"
    scheduler_postgresql_replicate_source_server_ids = {
      pg1 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-west-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/catalyst-west-scheduler-pg1-postgresql"
    }
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.postgresql.create_mode == "Replica"
    error_message = "the passive region's shared server must be created as a replica"
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.postgresql.source_server_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-west-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/catalyst-west-postgresql"
    error_message = "the replica must follow the active region's shared server"
  }

  # Nothing here asserts that administrator_login and administrator_password are
  # null on a replica, though the configuration sets them so and Azure refuses
  # the pair outright when create_mode is Replica. Both are Optional AND
  # Computed, so a mocked provider answers with a value of its own whatever the
  # configuration said, and an assertion on them would be reading the mock. The
  # branch they are on is the one create_mode and the database count below
  # already prove was taken.

  assert {
    condition     = length(azurerm_postgresql_flexible_server_database.postgresql) == 0
    error_message = "creating the database on a replica collides with the one replication already delivered"
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server_configuration.wal_level) == 0
    error_message = "a replica cannot be configured independently; its WAL level comes from the stream it replays"
  }

  # replication_role cannot be set at create time at all — Azure rejects it —
  # so a region cannot be built pre-promoted. It is created following, and
  # promoted by the second apply that is the failover step.
  assert {
    condition     = azurerm_postgresql_flexible_server.postgresql.replication_role == null
    error_message = "a freshly built replica is following, not promoted"
  }
}

# The failover step. Everything about the server stays where it is except the
# replication role — and that is the assertion this whole file exists for.
run "promotion_keeps_the_source_server_id" {
  command = plan

  variables {
    cluster_name                          = "catalyst-east"
    postgresql_replicate_source_server_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-west-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/catalyst-west-postgresql"
    postgresql_promote_replica            = true
    scheduler_postgresql_replicate_source_server_ids = {
      pg1 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-west-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/catalyst-west-scheduler-pg1-postgresql"
    }
    scheduler_postgresql_promote_replicas = {
      pg1 = true
    }
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.postgresql.replication_role == "None"
    error_message = "promotion is replication_role = None, and nothing else"
  }

  # source_server_id forces a new server. A promoted region that dropped it
  # would plan the destruction of the database it had just been failed over to.
  assert {
    condition     = azurerm_postgresql_flexible_server.postgresql.source_server_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-west-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/catalyst-west-postgresql"
    error_message = "a promoted server KEEPS its source server id: clearing it forces a new server, which destroys the data the promotion was for"
  }

  # Azure only accepts the promotion PATCH on a server whose create mode is
  # still Replica. Dropping it would make the promotion fail at apply.
  assert {
    condition     = azurerm_postgresql_flexible_server.postgresql.create_mode == "Replica"
    error_message = "Azure accepts replication_role = None only while create_mode is Replica; a promoted server keeps both"
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.scheduler_postgresql["pg1"].replication_role == "None" && azurerm_postgresql_flexible_server.scheduler_postgresql["pg1"].source_server_id != null
    error_message = "the scheduler servers are promoted the same way, and keep their source too"
  }
}

# Promoting with no source is the mistake the AWS spelling leads to: clear the
# replication source, set the promote flag, apply. On Azure that is a request to
# destroy the database. Refuse it at plan time rather than at 3am.
run "promoting_without_a_source_is_refused" {
  command = plan

  variables {
    cluster_name                          = "catalyst-east"
    postgresql_replicate_source_server_id = ""
    postgresql_promote_replica            = true
  }

  expect_failures = [var.postgresql_promote_replica]
}

# Every Flexible Server is created with a `postgres` database of its own, so a
# second one under that name cannot be created and the apply fails part-way
# through building the region. The AWS guide's variable of the same name has no
# such restriction, which is how the wrong default gets carried across.
run "naming_the_database_after_one_of_azures_own_is_refused" {
  command = plan

  variables {
    cluster_name       = "catalyst-west"
    postgresql_db_name = "postgres"
  }

  expect_failures = [var.postgresql_db_name]
}

# A group's passive region runs its scheduler's logical decoding against a
# standby, which PostgreSQL cannot do before 16.
run "a_group_pinned_below_postgresql_16_is_refused" {
  command = plan

  variables {
    cluster_name                          = "catalyst-east"
    postgresql_version                    = "15"
    postgresql_high_availability          = false
    postgresql_replicate_source_server_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-west-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/catalyst-west-postgresql"
  }

  expect_failures = [var.postgresql_version]
}

# Azure does not refuse high availability on a replica; it leaves the create in
# "Updating" until the provider times out, an hour later. Refused at plan time.
run "a_replica_with_high_availability_is_refused" {
  command = plan

  variables {
    cluster_name                          = "catalyst-east"
    postgresql_replicate_source_server_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-west-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/catalyst-west-postgresql"
    postgresql_high_availability          = true
  }

  expect_failures = [azurerm_postgresql_flexible_server.postgresql]
}
