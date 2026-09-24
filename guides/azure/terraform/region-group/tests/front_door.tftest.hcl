# The region group's front door: one cross-region load balancer over both
# regions' gateway frontends, and the wildcard domain pointing at it.
#
# These run offline. Finding a member's frontend means reading the load balancer
# AKS manages for that cluster, so a plan against an empty subscription reaches
# none of it. mock_provider stands in for Azure and each run supplies the two
# load balancers — except the runs that deliberately supply neither.
#
# Run with: terraform test

mock_provider "azurerm" {}

# A mocked resource gets a random string for every attribute, and azurerm
# validates the resource ids these are handed.
override_resource {
  target          = azurerm_resource_group.this
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-region-group-rg"
  }
}

override_resource {
  target          = azurerm_public_ip.front_door
  override_during = plan
  values = {
    id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-region-group-rg/providers/Microsoft.Network/publicIPAddresses/catalyst-region-group-pip"
    ip_address = "198.51.100.10"
  }
}

override_resource {
  target          = azurerm_lb.front_door
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-region-group-rg/providers/Microsoft.Network/loadBalancers/catalyst-region-group"
  }
}

override_resource {
  target          = azurerm_lb_backend_address_pool.regions
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-region-group-rg/providers/Microsoft.Network/loadBalancers/catalyst-region-group/backendAddressPools/regions"
  }
}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  tenant_id               = "11111111-1111-1111-1111-111111111111"
  region_ingress_endpoint = "catalyst.example.com"

  dns_zone_resource_group_name = "catalyst-west-rg"

  primary_cluster_name         = "catalyst-west"
  primary_node_resource_group  = "MC_catalyst-west-rg_catalyst-west_westus2"
  primary_gateway_public_ip_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-west-rg/providers/Microsoft.Network/publicIPAddresses/catalyst-west-gateway-pip"

  secondary_cluster_name         = "catalyst-east"
  secondary_node_resource_group  = "MC_catalyst-east-rg_catalyst-east_eastus2"
  secondary_gateway_public_ip_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-east-rg/providers/Microsoft.Network/publicIPAddresses/catalyst-east-gateway-pip"
}

run "both_regions_sit_behind_one_front_door" {
  command = plan

  override_data {
    target          = data.azurerm_lb.primary_gateway[0]
    override_during = plan
    values = {
      frontend_ip_configuration = [
        {
          id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_catalyst-west-rg_catalyst-west_westus2/providers/Microsoft.Network/loadBalancers/kubernetes/frontendIPConfigurations/gateway"
          name                 = "gateway"
          public_ip_address_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-west-rg/providers/Microsoft.Network/publicIPAddresses/catalyst-west-gateway-pip"
        },
        {
          id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_catalyst-west-rg_catalyst-west_westus2/providers/Microsoft.Network/loadBalancers/kubernetes/frontendIPConfigurations/outbound"
          name                 = "outbound"
          public_ip_address_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_catalyst-west-rg_catalyst-west_westus2/providers/Microsoft.Network/publicIPAddresses/egress"
        },
      ]
    }
  }

  override_data {
    target          = data.azurerm_lb.secondary_gateway[0]
    override_during = plan
    values = {
      frontend_ip_configuration = [
        {
          id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_catalyst-east-rg_catalyst-east_eastus2/providers/Microsoft.Network/loadBalancers/kubernetes/frontendIPConfigurations/gateway"
          name                 = "gateway"
          public_ip_address_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-east-rg/providers/Microsoft.Network/publicIPAddresses/catalyst-east-gateway-pip"
        },
      ]
    }
  }

  # Global, not Regional, is the whole of what makes this a front door — and
  # Azure offers no upgrade from one to the other.
  assert {
    condition     = azurerm_lb.front_door.sku == "Standard" && azurerm_lb.front_door.sku_tier == "Global"
    error_message = "the front door must be a Global tier Standard load balancer; a regional one cannot be upgraded to it later"
  }

  assert {
    condition     = azurerm_public_ip.front_door.sku_tier == "Global" && azurerm_public_ip.front_door.allocation_method == "Static"
    error_message = "the group's address must be a static Global one, or it is neither anycast nor stable across a failover"
  }

  assert {
    condition     = azurerm_lb_rule.front_door.protocol == "Tcp"
    error_message = "the gateway terminates TLS itself, so the front door must forward TCP rather than terminate anything"
  }

  # Off, not one relayed packet reached a node while every health metric read
  # healthy. AKS's own regional rule has floating IP on, and it accepts the
  # global address only when the Service names it.
  assert {
    condition     = azurerm_lb_rule.front_door.floating_ip_enabled == true
    error_message = "the front door rule needs floating IP, or no relayed connection reaches the gateway"
  }

  # Azure requires the global rule's backend port to equal the port the regional
  # rule fronts, which is the port the gateway serves.
  assert {
    condition     = azurerm_lb_rule.front_door.frontend_port == 443 && azurerm_lb_rule.front_door.backend_port == 443
    error_message = "the front door's backend port must match the port the regional load balancers front, which Azure requires and which is the port the gateway serves"
  }

  # The frontend is picked by the address the region's terraform created, not by
  # the name cloud-provider-azure happened to give it — the second entry in the
  # primary's list above is the cluster's egress frontend, and must not be
  # chosen.
  assert {
    condition     = one(azurerm_lb_backend_address_pool_address.primary).backend_address_ip_configuration_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_catalyst-west-rg_catalyst-west_westus2/providers/Microsoft.Network/loadBalancers/kubernetes/frontendIPConfigurations/gateway"
    error_message = "the first region's backend must be the frontend carrying that region's gateway address, not another frontend on the same cluster load balancer"
  }

  assert {
    condition     = one(azurerm_lb_backend_address_pool_address.secondary).backend_address_ip_configuration_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_catalyst-east-rg_catalyst-east_eastus2/providers/Microsoft.Network/loadBalancers/kubernetes/frontendIPConfigurations/gateway"
    error_message = "the second region's backend must be that region's own gateway frontend"
  }

  assert {
    condition     = azurerm_dns_a_record.wildcard.name == "*" && azurerm_dns_a_record.wildcard.zone_name == "catalyst.example.com"
    error_message = "the wildcard record must cover every name the group serves"
  }

  assert {
    condition     = azurerm_dns_a_record.wildcard.records == toset(["198.51.100.10"])
    error_message = "the wildcard record must resolve to the front door, not to either region"
  }

  assert {
    condition     = output.region_endpoints.primary == "catalyst-west.catalyst.example.com"
    error_message = "each region needs a name of its own to be probed on"
  }
}

# A planned failover drains a region before its database is promoted, rather
# than letting the promotion itself move the traffic. Azure has no percentage
# dial, so draining removes the region from the backend pool.
run "draining_a_region_takes_it_out_of_the_pool_and_leaves_the_other" {
  command = plan

  variables {
    primary_drained = true
  }

  override_data {
    target          = data.azurerm_lb.secondary_gateway[0]
    override_during = plan
    values = {
      frontend_ip_configuration = [
        {
          id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_catalyst-east-rg_catalyst-east_eastus2/providers/Microsoft.Network/loadBalancers/kubernetes/frontendIPConfigurations/gateway"
          name                 = "gateway"
          public_ip_address_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-east-rg/providers/Microsoft.Network/publicIPAddresses/catalyst-east-gateway-pip"
        },
      ]
    }
  }

  assert {
    condition     = length(azurerm_lb_backend_address_pool_address.primary) == 0
    error_message = "the drained region must take no new connections"
  }

  assert {
    condition     = length(azurerm_lb_backend_address_pool_address.secondary) == 1
    error_message = "the region being failed over to must stay in the pool"
  }

  # A drained region is not read, so draining one works while it is unreachable
  # — which is the case draining exists for.
  assert {
    condition     = output.gateway_frontend_ip_configurations.primary == null
    error_message = "a drained region is out of the pool and has no frontend registered"
  }
}

# Draining both empties the pool and takes the group offline. It is never the
# thing anyone meant.
run "draining_both_regions_is_refused" {
  command = plan

  variables {
    primary_drained   = true
    secondary_drained = true
  }

  expect_failures = [var.secondary_drained]
}

# The frontend appears when the Catalyst agent's gateway Service claims the
# region's address, so this stack cannot be applied before the agent is
# installed in both regions.
run "a_region_without_its_agent_installed_is_refused" {
  command = plan

  override_data {
    target          = data.azurerm_lb.primary_gateway[0]
    override_during = plan
    values = {
      frontend_ip_configuration = [
        {
          id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_catalyst-west-rg_catalyst-west_westus2/providers/Microsoft.Network/loadBalancers/kubernetes/frontendIPConfigurations/gateway"
          name                 = "gateway"
          public_ip_address_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-west-rg/providers/Microsoft.Network/publicIPAddresses/catalyst-west-gateway-pip"
        },
      ]
    }
  }

  # The cluster load balancer exists — it carries the cluster's egress — but no
  # frontend on it carries this region's gateway address yet.
  override_data {
    target          = data.azurerm_lb.secondary_gateway[0]
    override_during = plan
    values = {
      frontend_ip_configuration = [
        {
          id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_catalyst-east-rg_catalyst-east_eastus2/providers/Microsoft.Network/loadBalancers/kubernetes/frontendIPConfigurations/outbound"
          name                 = "outbound"
          public_ip_address_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_catalyst-east-rg_catalyst-east_eastus2/providers/Microsoft.Network/publicIPAddresses/egress"
        },
      ]
    }
  }

  expect_failures = [azurerm_lb_backend_address_pool_address.secondary]
}

# Losing a region is when draining is worth reaching for, and a region that is
# down cannot answer a lookup. Given both frontend ids this stack reads nothing
# from either member region, so it still plans with both of them unreachable —
# which is what the absence of any override_data here stands for.
run "the_front_door_plans_without_reading_either_member_region" {
  command = plan

  variables {
    primary_gateway_frontend_ip_configuration_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_catalyst-west-rg_catalyst-west_westus2/providers/Microsoft.Network/loadBalancers/kubernetes/frontendIPConfigurations/gateway"
    secondary_gateway_frontend_ip_configuration_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_catalyst-east-rg_catalyst-east_eastus2/providers/Microsoft.Network/loadBalancers/kubernetes/frontendIPConfigurations/gateway"
    primary_drained                                = true
  }

  assert {
    condition     = length(data.azurerm_lb.primary_gateway) == 0 && length(data.azurerm_lb.secondary_gateway) == 0
    error_message = "a given frontend id must replace the lookup, not sit beside it — the lookup is the thing an unreachable region cannot serve"
  }

  assert {
    condition     = one(azurerm_lb_backend_address_pool_address.secondary).backend_address_ip_configuration_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_catalyst-east-rg_catalyst-east_eastus2/providers/Microsoft.Network/loadBalancers/kubernetes/frontendIPConfigurations/gateway"
    error_message = "the given frontend id must be the backend the front door registers"
  }

  assert {
    condition     = length(azurerm_lb_backend_address_pool_address.primary) == 0
    error_message = "draining the lost region is the point of being able to apply this at all"
  }
}

# One frontend given and the other discovered is the ordinary case part-way
# through recording them, and must behave like either one alone.
run "a_given_frontend_and_a_discovered_one_mix" {
  command = plan

  variables {
    secondary_gateway_frontend_ip_configuration_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_catalyst-east-rg_catalyst-east_eastus2/providers/Microsoft.Network/loadBalancers/kubernetes/frontendIPConfigurations/gateway"
  }

  override_data {
    target          = data.azurerm_lb.primary_gateway[0]
    override_during = plan
    values = {
      frontend_ip_configuration = [
        {
          id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_catalyst-west-rg_catalyst-west_westus2/providers/Microsoft.Network/loadBalancers/kubernetes/frontendIPConfigurations/gateway"
          name                 = "gateway"
          public_ip_address_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/catalyst-west-rg/providers/Microsoft.Network/publicIPAddresses/catalyst-west-gateway-pip"
        },
      ]
    }
  }

  assert {
    condition     = length(data.azurerm_lb.secondary_gateway) == 0
    error_message = "the given side must not be looked up"
  }

  assert {
    condition     = one(azurerm_lb_backend_address_pool_address.primary).backend_address_ip_configuration_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_catalyst-west-rg_catalyst-west_westus2/providers/Microsoft.Network/loadBalancers/kubernetes/frontendIPConfigurations/gateway"
    error_message = "the discovered side must still resolve by its address"
  }
}

# The front door object can only be created in one of Azure's home regions. That
# is a constraint on this stack alone: the member regions are anywhere.
run "a_front_door_outside_a_home_region_is_refused" {
  command = plan

  variables {
    location = "westus2"
  }

  expect_failures = [var.location]
}
