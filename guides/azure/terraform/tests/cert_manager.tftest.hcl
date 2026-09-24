# cert-manager's identity for the DNS-01 challenge.
#
# The gateway's wildcard certificate is issued by cert-manager solving an ACME
# DNS-01 challenge, which means writing a TXT record into the region's DNS zone.
# What has to be right is which zone it is granted on: a region that created the
# zone is granted on its own, and the second member of a region group — which
# serves the same wildcard domain and therefore joined the first region's zone —
# has to be granted on THAT zone, in the other region's resource group.
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

# A region on its own creates the zone and is granted on the one it created, so
# there is nothing to look up.
run "a_standalone_region_is_granted_on_the_zone_it_created" {
  command = plan

  variables {
    cluster_name                 = "catalyst-west"
    region_group_member          = false
    dns_zone_resource_group_name = ""
  }

  assert {
    condition     = length(azurerm_user_assigned_identity.cert_manager) == 1
    error_message = "a region serving a domain gets an identity for cert-manager"
  }

  assert {
    condition     = length(data.azurerm_dns_zone.cert_manager) == 0
    error_message = "a region that created its own zone looks up nothing"
  }

  assert {
    condition     = length(azurerm_role_assignment.cert_manager_dns) == 1
    error_message = "cert-manager is granted on the zone"
  }
}

# The second member joined the first region's zone, so it must be granted on
# that zone rather than on one of its own.
run "a_joining_member_is_granted_on_the_zone_it_joined" {
  command = plan

  variables {
    cluster_name                 = "catalyst-east"
    region_group_member          = true
    dns_zone_resource_group_name = "catalyst-west-rg"
  }

  assert {
    condition     = length(azurerm_dns_zone.catalyst) == 0
    error_message = "a joining member creates no zone of its own"
  }

  assert {
    condition     = length(data.azurerm_dns_zone.cert_manager) == 1
    error_message = "a joining member looks up the zone it joined"
  }

  assert {
    condition     = one(azurerm_role_assignment.cert_manager_dns).scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-west-rg/providers/Microsoft.Network/dnsZones/catalyst.example.com"
    error_message = "cert-manager in the second region is granted on the FIRST region's zone, not on a zone of its own"
  }

  assert {
    condition     = one(azurerm_role_assignment.cert_manager_dns).role_definition_name == "DNS Zone Contributor"
    error_message = "writing a challenge record needs DNS Zone Contributor"
  }
}

# Entra ID matches the federated credential on the subject of the projected
# token, so it has to name cert-manager's service account exactly as its chart
# installs it. A mismatch fails at certificate-issuing time, not at apply.
run "the_federated_credential_names_cert_managers_service_account" {
  command = plan

  variables {
    cluster_name                 = "catalyst-west"
    region_group_member          = true
    dns_zone_resource_group_name = ""
  }

  assert {
    condition     = one(azurerm_federated_identity_credential.cert_manager).subject == "system:serviceaccount:cert-manager:cert-manager"
    error_message = "the federated subject must be cert-manager's service account"
  }

  assert {
    condition     = one(azurerm_federated_identity_credential.cert_manager).audience == tolist(["api://AzureADTokenExchange"])
    error_message = "Entra ID only accepts the AzureADTokenExchange audience"
  }
}

# A region with no domain serves no certificate, so it needs none of this.
run "a_region_without_a_domain_gets_no_cert_manager_identity" {
  command = plan

  variables {
    cluster_name            = "catalyst-west"
    region_ingress_endpoint = null
  }

  assert {
    condition     = length(azurerm_user_assigned_identity.cert_manager) == 0
    error_message = "no domain, no certificate, no identity"
  }
}
