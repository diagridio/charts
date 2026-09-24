# Peer this region's virtual network with an external one.
#
# Azure peering is two one-sided resources rather than one connection with an
# auto-accept flag: this side is created here, and the owner of the peer network
# creates the matching one pointing back. Routing follows the peering itself, so
# there are no route table entries to add as there are on AWS.
#
# The other region of a region group is peered separately, below — not through
# this, which stays free for the network the region is administered from.
resource "azurerm_virtual_network_peering" "external" {
  count = var.enable_peering ? 1 : 0

  name                      = "${var.cluster_name}-peer"
  resource_group_name       = azurerm_resource_group.this.name
  virtual_network_name      = azurerm_virtual_network.this.name
  remote_virtual_network_id = var.peer_vnet_id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

# The two regions of a group.
#
# A cross-region Flexible Server replica of a VNet-integrated server replicates
# over the two virtual networks, not around them: Azure requires them to be
# peered, with port 5432 open both ways, and their address spaces not to
# overlap. Without the peering the replica create never finishes — it sits in
# "Updating" with no replication state until the provider's timeout.
#
# Both halves, and both private DNS links, belong to the region that JOINS the
# group, because it is the only one applied after both networks exist and the
# replica it creates cannot be created before them. It keeps them for the
# group's lifetime: region_group_peer_vnet_id never changes across a failover,
# so a promotion or a rebuild never plans them.
#
# The other region's names are this stack's own conventions — its network is
# "<cluster>-vnet" and its database zone is "<cluster>.private.postgres…" in the
# same resource group — so both members must be built from this stack.
locals {
  region_group_peered       = var.region_group_peer_vnet_id != ""
  region_group_peer         = local.region_group_peered ? provider::azurerm::parse_resource_id(var.region_group_peer_vnet_id) : null
  region_group_peer_cluster = local.region_group_peered ? trimsuffix(local.region_group_peer.resource_name, "-vnet") : ""
}

resource "azurerm_virtual_network_peering" "region_group_to_peer" {
  count = local.region_group_peered ? 1 : 0

  name                      = "${var.cluster_name}-to-${local.region_group_peer_cluster}"
  resource_group_name       = azurerm_resource_group.this.name
  virtual_network_name      = azurerm_virtual_network.this.name
  remote_virtual_network_id = var.region_group_peer_vnet_id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "region_group_from_peer" {
  count = local.region_group_peered ? 1 : 0

  name                      = "${local.region_group_peer_cluster}-to-${var.cluster_name}"
  resource_group_name       = local.region_group_peer.resource_group_name
  virtual_network_name      = local.region_group_peer.resource_name
  remote_virtual_network_id = azurerm_virtual_network.this.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

# Private DNS is scoped to the networks a zone is linked to, so each region's
# database name has to resolve in the other's network as well — in both
# directions, because after a failover it is the other region that follows.
resource "azurerm_private_dns_zone_virtual_network_link" "postgresql_region_group_peer" {
  count = local.region_group_peered ? 1 : 0

  name                 = "${var.cluster_name}-postgresql-${local.region_group_peer_cluster}"
  private_dns_zone_id  = azurerm_private_dns_zone.postgresql.id
  virtual_network_id   = var.region_group_peer_vnet_id
  registration_enabled = false
  tags                 = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgresql_region_group_peer_zone" {
  count = local.region_group_peered ? 1 : 0

  name                 = "${local.region_group_peer_cluster}-postgresql-${var.cluster_name}"
  private_dns_zone_id  = "/subscriptions/${local.region_group_peer.subscription_id}/resourceGroups/${local.region_group_peer.resource_group_name}/providers/Microsoft.Network/privateDnsZones/${local.region_group_peer_cluster}.private.postgres.database.azure.com"
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = false
  tags                 = var.tags
}
