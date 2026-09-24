# Which DNS records a region writes, and why a region group's member writes a
# different one.
#
# Both members of a group serve the same wildcard domain, so neither of them can
# own that domain's record — it can only resolve to one thing, and that thing is
# the group's front door. A member writes a record for its own name instead,
# which is what every failover check asks.
#
# Run with: terraform test

mock_provider "azurerm" {}

# plan rather than apply, for the reason given in postgresql_replica.tftest.hcl.

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

# The zone a joining region reads to grant cert-manager on. A data source is
# read during plan, so unlike a resource its id is a concrete value the provider
# parses straight away — a mocked random string is rejected where a
# known-after-apply resource id would not be.
override_data {
  target = data.azurerm_dns_zone.cert_manager
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-west-rg/providers/Microsoft.Network/dnsZones/catalyst.example.com"
  }
}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  tenant_id               = "11111111-1111-1111-1111-111111111111"
  region_ingress_endpoint = "catalyst.example.com"
  postgresql_password     = "not-a-real-password"
  enable_bastion          = false
  enable_peering          = false
}

# A region on its own owns the wildcard domain, creates the zone for it, and
# points it at its own address.
run "a_standalone_region_owns_the_wildcard" {
  command = plan

  variables {
    cluster_name                 = "catalyst-west"
    region_group_member          = false
    dns_zone_resource_group_name = ""
  }

  assert {
    condition     = length(azurerm_dns_zone.catalyst) == 1
    error_message = "a region not joining an existing zone creates one"
  }

  assert {
    condition     = one(azurerm_dns_a_record.catalyst_wildcard).name == "*"
    error_message = "the wildcard record must cover every name the region serves"
  }

  assert {
    condition     = one(azurerm_dns_a_record.catalyst_wildcard).records == toset(["198.51.100.10"])
    error_message = "the wildcard must resolve to this region's own gateway address"
  }

  assert {
    condition     = length(azurerm_dns_a_record.catalyst_region) == 0
    error_message = "a standalone region needs no name of its own; the wildcard already reaches it"
  }

  assert {
    condition     = output.region_ingress_endpoint == "https://*.catalyst.example.com:443"
    error_message = "the ingress endpoint is what `diagrid region update` is given"
  }
}

# The first region of a group. It still creates the zone — it is the one that
# owns it — but it writes no wildcard, because the front door will.
run "the_first_member_creates_the_zone_and_leaves_the_wildcard_alone" {
  command = plan

  variables {
    cluster_name                 = "catalyst-west"
    region_group_member          = true
    dns_zone_resource_group_name = ""
  }

  assert {
    condition     = length(azurerm_dns_zone.catalyst) == 1
    error_message = "the first member of a group creates the zone both members share"
  }

  assert {
    condition     = length(azurerm_dns_a_record.catalyst_wildcard) == 0
    error_message = "a member must not write the wildcard: the group's front door owns it, and a member writing it would take the group's traffic"
  }

  assert {
    condition     = one(azurerm_dns_a_record.catalyst_region).name == "catalyst-west"
    error_message = "a member needs a name of its own, because that is what a failover check asks whether it accepts writes"
  }

  assert {
    condition     = output.dns_zone_resource_group_name == "catalyst-west-rg"
    error_message = "the second region joins this zone by its resource group, so it has to be an output"
  }
}

# The second region of a group joins the first one's zone rather than creating
# its own, and writes only its own name into it.
run "the_second_member_joins_the_first_regions_zone" {
  command = plan

  variables {
    cluster_name                 = "catalyst-east"
    region_group_member          = true
    dns_zone_resource_group_name = "catalyst-west-rg"
  }

  assert {
    condition     = length(azurerm_dns_zone.catalyst) == 0
    error_message = "a region given another region's zone must not create a second zone for the same domain"
  }

  assert {
    condition     = one(azurerm_dns_a_record.catalyst_region).resource_group_name == "catalyst-west-rg"
    error_message = "the second member's record belongs in the zone the first member created"
  }

  assert {
    condition     = one(azurerm_dns_a_record.catalyst_region).name == "catalyst-east"
    error_message = "each member is reachable at its own name"
  }
}

# Joining another region's zone without saying so is the mistake that costs the
# first region its traffic: the wildcard record would be rewritten to point at
# this region alone. The precondition catches it at plan time.
run "a_member_that_forgot_to_say_so_is_refused" {
  command = plan

  variables {
    cluster_name                 = "catalyst-east"
    region_group_member          = false
    dns_zone_resource_group_name = "catalyst-west-rg"
  }

  expect_failures = [azurerm_dns_a_record.catalyst_wildcard]
}
