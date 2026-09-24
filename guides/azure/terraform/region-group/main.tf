# The front door for a Catalyst region group.
#
# Both member regions serve the same wildcard domain, and exactly one of them
# accepts writes at a time. This stack puts one cross-region (Global tier) load
# balancer in front of the two regions' gateway load balancers and points the
# wildcard domain at it, so the group has a single entry point whose backend can
# change without anything downstream re-resolving a name.
#
# Where the failover decision comes from
# --------------------------------------
# A cross-region load balancer does not health check its backends itself. It
# reads the health the regional load balancers already report, every five
# seconds, and takes a region out of rotation when that region's availability
# drops to zero. So the failover signal is configured on the Catalyst gateway
# Service, not here: the guide sets the gateway's health probe to
# GET /diagrid/region/writable, which every region answers with 200 while its
# PostgreSQL accepts writes and 503 while it is a replica. Azure's HTTP and
# HTTPS probes treat only 200 as healthy, which is exactly those semantics.
#
# The passive region's probe therefore fails, the front door sends no traffic
# there, and promoting the replica moves the traffic. Nothing here knows which
# region is active, and neither does Catalyst.
#
# This stack is applied once for the group, from its own state, after both
# regions have been applied and have the Catalyst agent installed.

locals {
  resource_group_name = var.resource_group_name != "" ? var.resource_group_name : "${var.name}-rg"
}

resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = var.location
  tags     = var.tags
}

# Each member's gateway frontend, either given or discovered.
#
# Discovery reads the load balancer AKS manages for the cluster — always named
# `kubernetes`, in the node resource group — and picks the frontend carrying the
# address that region's terraform created. Matching on the address rather than
# on a frontend name is what makes it exact: cloud-provider-azure names a
# frontend after the Service's identity, which is not something this stack
# should have to predict.
#
# It costs a read in that region's resource group, though, and a region that is
# down cannot answer one — which would make this stack unplannable exactly when
# a member region has been lost and draining it is the thing you want to reach
# for. So each member's frontend id can be given instead. Give both and this
# stack reads nothing from either member region.
data "azurerm_lb" "primary_gateway" {
  count = var.primary_gateway_frontend_ip_configuration_id == "" ? 1 : 0

  name                = "kubernetes"
  resource_group_name = var.primary_node_resource_group
}

data "azurerm_lb" "secondary_gateway" {
  count = var.secondary_gateway_frontend_ip_configuration_id == "" ? 1 : 0

  name                = "kubernetes"
  resource_group_name = var.secondary_node_resource_group
}

locals {
  discovered_primary_frontend_id = try(one([
    for f in data.azurerm_lb.primary_gateway[0].frontend_ip_configuration :
    f.id if f.public_ip_address_id == var.primary_gateway_public_ip_id
  ]), null)

  discovered_secondary_frontend_id = try(one([
    for f in data.azurerm_lb.secondary_gateway[0].frontend_ip_configuration :
    f.id if f.public_ip_address_id == var.secondary_gateway_public_ip_id
  ]), null)

  primary_frontend_id = (var.primary_gateway_frontend_ip_configuration_id != ""
    ? var.primary_gateway_frontend_ip_configuration_id
  : local.discovered_primary_frontend_id)

  secondary_frontend_id = (var.secondary_gateway_frontend_ip_configuration_id != ""
    ? var.secondary_gateway_frontend_ip_configuration_id
  : local.discovered_secondary_frontend_id)

  has_primary_frontend   = local.primary_frontend_id != null
  has_secondary_frontend = local.secondary_frontend_id != null

  # A drained region is removed from the backend pool, so its frontend is not
  # needed and its region is not read.
  primary_in_pool   = !var.primary_drained
  secondary_in_pool = !var.secondary_drained
}

# The group's static anycast address. It is advertised from every participating
# Azure region, and it does not change when the group fails over — so it is what
# to allowlist in a firewall.
resource "azurerm_public_ip" "front_door" {
  name                = "${var.name}-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  sku_tier            = "Global"
  tags                = var.tags
}

# Global rather than Regional is the whole of what makes this a front door. It
# cannot be changed later: Azure has no upgrade from a regional load balancer to
# a global one, only a new one.
resource "azurerm_lb" "front_door" {
  name                = var.name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Standard"
  sku_tier            = "Global"
  tags                = var.tags

  frontend_ip_configuration {
    name                 = "front-door"
    public_ip_address_id = azurerm_public_ip.front_door.id
  }
}

resource "azurerm_lb_backend_address_pool" "regions" {
  name            = "regions"
  loadbalancer_id = azurerm_lb.front_door.id
}

# The backend pool of a global load balancer holds regional load balancer
# frontends rather than addresses or network interfaces. Each member region
# contributes exactly one.
resource "azurerm_lb_backend_address_pool_address" "primary" {
  count = local.primary_in_pool ? 1 : 0

  name                                = var.primary_cluster_name
  backend_address_pool_id             = azurerm_lb_backend_address_pool.regions.id
  backend_address_ip_configuration_id = local.primary_frontend_id

  lifecycle {
    precondition {
      condition     = local.has_primary_frontend
      error_message = "No gateway frontend found for ${var.primary_cluster_name}. Install the Catalyst agent in that region first — the frontend is created when its gateway Service claims the region's address. Check that primary_node_resource_group and primary_gateway_public_ip_id are that region's aks_node_resource_group and gateway_public_ip_id outputs. If that region is unreachable, set primary_gateway_frontend_ip_configuration_id instead."
    }
  }
}

resource "azurerm_lb_backend_address_pool_address" "secondary" {
  count = local.secondary_in_pool ? 1 : 0

  name                                = var.secondary_cluster_name
  backend_address_pool_id             = azurerm_lb_backend_address_pool.regions.id
  backend_address_ip_configuration_id = local.secondary_frontend_id

  lifecycle {
    precondition {
      condition     = local.has_secondary_frontend
      error_message = "No gateway frontend found for ${var.secondary_cluster_name}. Install the Catalyst agent in that region first — the frontend is created when its gateway Service claims the region's address. Check that secondary_node_resource_group and secondary_gateway_public_ip_id are that region's aks_node_resource_group and gateway_public_ip_id outputs. If that region is unreachable, set secondary_gateway_frontend_ip_configuration_id instead."
    }
  }
}

# One TCP rule: the gateway terminates TLS itself and routes on SNI, so the
# front door must not terminate anything.
#
# The backend port has to equal the port the REGIONAL rule fronts, which Azure
# requires and which is the port the gateway serves. There is no probe here on
# purpose — a global load balancer inherits the regional ones' health, and
# giving it a probe of its own is not something Azure offers.
#
# Floating IP is on because AKS is built for it. The regional load balancer
# AKS programs has floating IP on too, so a relayed connection reaches the
# node still addressed to this front door's global address, and AKS accepts
# that address only when the gateway Service names it in
# service.beta.kubernetes.io/azure-additional-public-ips — which adds it to
# the node security group and to kube-proxy. With floating IP off here, not
# one relayed packet reached either region's nodes, while both regions and
# this front door all reported healthy.
resource "azurerm_lb_rule" "front_door" {
  name                           = "https"
  loadbalancer_id                = azurerm_lb.front_door.id
  protocol                       = "Tcp"
  frontend_port                  = var.listener_port
  backend_port                   = var.listener_port
  frontend_ip_configuration_name = one(azurerm_lb.front_door.frontend_ip_configuration).name
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.regions.id]
  load_distribution              = var.load_distribution
  floating_ip_enabled            = true
}

# Every name under the domain — a project's http- and grpc- hostnames, and the
# region's service names — resolves to the front door's static address, for
# every client, with no per-region record and nothing to re-resolve on failover.
resource "azurerm_dns_a_record" "wildcard" {
  name                = "*"
  zone_name           = var.region_ingress_endpoint
  resource_group_name = var.dns_zone_resource_group_name
  ttl                 = 60
  records             = [azurerm_public_ip.front_door.ip_address]
  tags                = var.tags
}
