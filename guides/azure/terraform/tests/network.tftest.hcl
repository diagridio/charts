# The region's network: what has to be open for the gateway to be reached, and
# what has to be declared for the stack to converge.
#
# Both were found only by applying against real Azure — neither fails a plan —
# so these runs pin the configuration that fixed them.
#
# Run with: terraform test

mock_provider "azurerm" {}

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
  cluster_name            = "catalyst-west"
  region_ingress_endpoint = "catalyst.example.com"
  postgresql_password     = "not-a-real-password"
}

# AKS writes the gateway's allow rule into the security group in its node
# resource group. This one is on the subnet, is evaluated as well, and denies
# the internet by default — so without this rule the gateway answers nothing.
run "the_gateway_is_open_to_the_internet_on_443" {
  command = plan

  assert {
    condition = anytrue([
      for r in azurerm_network_security_group.aks.security_rule :
      r.direction == "Inbound" && r.access == "Allow" && r.protocol == "Tcp" &&
      r.destination_port_range == "443" && r.source_address_prefix == "Internet" &&
      r.destination_address_prefix == "*"
    ])
    error_message = "the AKS subnet's security group must allow the internet on 443 to any address: relayed traffic is addressed to the front door"
  }
}

# Azure attaches this endpoint when the Flexible Server is created. Undeclared,
# every later plan removes it, and failover.sh refuses any promotion whose plan
# touches something outside the Flexible Server family.
run "the_database_subnet_declares_the_endpoint_azure_adds" {
  command = plan

  assert {
    condition     = [for e in azurerm_subnet.database.service_endpoint : e.service] == ["Microsoft.Storage"]
    error_message = "the database subnet must declare the Microsoft.Storage endpoint, or the stack never converges"
  }
}

# A standalone region, and the first region of a group, peer nothing.
run "a_region_without_a_group_peer_builds_no_peering" {
  command = plan

  assert {
    condition = (
      length(azurerm_virtual_network_peering.region_group_to_peer) == 0 &&
      length(azurerm_virtual_network_peering.region_group_from_peer) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.postgresql_region_group_peer) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.postgresql_region_group_peer_zone) == 0
    )
    error_message = "nothing is peered until region_group_peer_vnet_id is set"
  }
}

# The joining region owns both halves: the replica it creates cannot exist
# before them, and it is the only region applied after both networks exist.
run "the_joining_region_peers_both_ways_and_links_both_zones" {
  command = plan

  variables {
    cluster_name              = "catalyst-east"
    region_group_peer_vnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-west-rg/providers/Microsoft.Network/virtualNetworks/catalyst-west-vnet"
  }

  assert {
    condition     = one(azurerm_virtual_network_peering.region_group_to_peer).remote_virtual_network_id == var.region_group_peer_vnet_id
    error_message = "this region's half must point at the other region's network"
  }

  assert {
    condition = (
      one(azurerm_virtual_network_peering.region_group_from_peer).resource_group_name == "catalyst-west-rg" &&
      one(azurerm_virtual_network_peering.region_group_from_peer).virtual_network_name == "catalyst-west-vnet" &&
      one(azurerm_virtual_network_peering.region_group_from_peer).name == "catalyst-west-to-catalyst-east"
    )
    error_message = "the other half must be created on the other region's network"
  }

  assert {
    condition     = one(azurerm_private_dns_zone_virtual_network_link.postgresql_region_group_peer).virtual_network_id == var.region_group_peer_vnet_id
    error_message = "this region's database name must resolve in the other region's network"
  }

  assert {
    condition     = one(azurerm_private_dns_zone_virtual_network_link.postgresql_region_group_peer_zone).private_dns_zone_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-west-rg/providers/Microsoft.Network/privateDnsZones/catalyst-west.private.postgres.database.azure.com"
    error_message = "the other region's database zone must be linked to this region's network"
  }
}

run "a_peer_that_is_not_a_vnet_this_stack_built_is_refused" {
  command = plan

  variables {
    region_group_peer_vnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/corp-rg/providers/Microsoft.Network/virtualNetworks/corp"
  }

  expect_failures = [var.region_group_peer_vnet_id]
}
