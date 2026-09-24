# The optional pieces of a region: the bastion and the virtual network peering.
#
# Both are count-gated, so the rest of the suite — which leaves them off —
# plans neither. A path nothing plans is a path whose references are never
# checked, which is how a role assignment ends up pointing at an identity its
# virtual machine does not have.
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

override_resource {
  target          = azurerm_subnet.bastion
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-rg/providers/Microsoft.Network/virtualNetworks/catalyst-vnet/subnets/catalyst-bastion-subnet"
  }
}

override_resource {
  target          = azurerm_network_security_group.bastion
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-rg/providers/Microsoft.Network/networkSecurityGroups/catalyst-bastion-nsg"
  }
}

override_resource {
  target          = azurerm_public_ip.bastion
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-rg/providers/Microsoft.Network/publicIPAddresses/catalyst-bastion-pip"
  }
}

override_resource {
  target          = azurerm_network_interface.bastion
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-rg/providers/Microsoft.Network/networkInterfaces/catalyst-bastion-nic"
  }
}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  tenant_id               = "11111111-1111-1111-1111-111111111111"
  cluster_name            = "catalyst-west"
  region_ingress_endpoint = "catalyst.example.com"
  postgresql_password     = "not-a-real-password"
}

run "a_region_with_a_bastion_plans" {
  command = plan

  variables {
    enable_bastion = true
    # A throwaway key generated for this test. Azure parses the key material,
    # so a made-up string is rejected before the plan is produced.
    bastion_ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDPKgCswGKRNa7t90ZBcbi7D3ijVBpMBeoWl0OsKkzVa1P1OmfYWkuVLQURThmE+XmzmdTelqgTWIfAVYpGF4ty9joemm4JvilOMZa/3nCBefI18SuFF3WNkNc7CGnKRI3YIvWOX3laQq6MUO1Wh0PC0f5ihQ6ZkShMYhXJc1gAt6uOmQpdCYwZ5Vd7hLJcujjN/PmuQ6Nhca9X5K0Nqe6tb+9oq5ZnJm7MRKWGRbbMgxd/JzhyWpyl/k6qbRGblYCRqUT+uABCpwL9R0Wnd7vVF5CFsgWFoAVtnVgKXS70CFLfVXTe6hlL7exQXuBQIvzT8SJrQsgMYD69pMFv5xxn terraform-test@example.com"
    enable_peering         = false
  }

  assert {
    condition     = length(azurerm_linux_virtual_machine.bastion) == 1
    error_message = "enable_bastion must build the host"
  }

  # The role assignments below read the machine's identity. A machine with no
  # identity block has none, and the reference fails at apply rather than at
  # validate — which is exactly the failure this run exists to catch.
  assert {
    condition     = one(azurerm_linux_virtual_machine.bastion).identity[0].type == "SystemAssigned"
    error_message = "the bastion needs an identity of its own: the cluster role assignments are granted to it"
  }

  assert {
    condition     = length(azurerm_role_assignment.bastion_cluster_admin) == 1 && length(azurerm_role_assignment.bastion_cluster_user) == 1
    error_message = "the bastion reaches the cluster as itself, so both role assignments come with it"
  }

  assert {
    condition     = one(one(azurerm_network_security_group.bastion).security_rule).source_address_prefix == "0.0.0.0/0"
    error_message = "the ssh rule must carry bastion_allowed_cidr"
  }
}

# An Azure Linux virtual machine has no password login, so a host built without
# a key cannot be reached at all — and would sit there costing money until
# someone noticed.
run "a_bastion_without_a_key_is_refused" {
  command = plan

  variables {
    enable_bastion         = true
    bastion_ssh_public_key = ""
  }

  expect_failures = [azurerm_linux_virtual_machine.bastion]
}

run "a_region_with_peering_plans" {
  command = plan

  variables {
    enable_bastion = false
    enable_peering = true
    peer_vnet_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/corp-rg/providers/Microsoft.Network/virtualNetworks/corp-vnet"
  }

  assert {
    condition     = one(azurerm_virtual_network_peering.external).remote_virtual_network_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/corp-rg/providers/Microsoft.Network/virtualNetworks/corp-vnet"
    error_message = "peering must point at the network it was given"
  }

  # Azure peering is two one-sided resources. This stack owns this side only,
  # and the peer network's owner creates the one pointing back.
  assert {
    condition     = one(azurerm_virtual_network_peering.external).virtual_network_name == "catalyst-west-vnet"
    error_message = "this side of the peering belongs to this region's own network"
  }
}
