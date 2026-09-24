# The public DNS zone for the region's wildcard domain.
#
# Only created when this region is not joining an existing one. The second
# region of a region group passes dns_zone_resource_group_name so that both
# regions share one wildcard domain.
resource "azurerm_dns_zone" "catalyst" {
  count = var.region_ingress_endpoint != null && var.dns_zone_resource_group_name == "" ? 1 : 0

  name                = var.region_ingress_endpoint
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

locals {
  dns_enabled = var.region_ingress_endpoint != null

  # Azure addresses a record by zone name and resource group. The zone's name is
  # the ingress endpoint, which both regions of a group already share; only the
  # resource group has to be passed between them.
  dns_zone_resource_group = (var.dns_zone_resource_group_name != ""
    ? var.dns_zone_resource_group_name
  : azurerm_resource_group.this.name)

  wildcard_domain         = local.dns_enabled ? "*.${var.region_ingress_endpoint}" : null
  region_ingress_endpoint = local.dns_enabled ? "https://*.${var.region_ingress_endpoint}:443" : null
}

# The wildcard record for the region's own domain.
#
# A region group has no per-region wildcard record: both regions serve the same
# names, so the name can only resolve to one thing, and that thing is the
# group's front door. The region-group stack owns it. See region-group/.
#
# Unlike the AWS guide's, this record is not gated on the Catalyst agent having
# been installed. The address it points at is created by this configuration
# rather than by the agent's gateway Service, so it exists from the first apply
# and the record can be written straight away. What the agent still decides is
# whether anything answers on it.
resource "azurerm_dns_a_record" "catalyst_wildcard" {
  count = local.dns_enabled && !var.region_group_member ? 1 : 0

  name                = "*"
  zone_name           = var.region_ingress_endpoint
  resource_group_name = local.dns_zone_resource_group
  ttl                 = 60
  records             = [azurerm_public_ip.gateway.ip_address]
  tags                = var.tags

  # A region given another region's zone resource group is a member of that
  # region's group. Left unmarked it would write the same wildcard name the
  # other region wrote, and the second apply would take over the first region's
  # record.
  lifecycle {
    precondition {
      condition     = var.dns_zone_resource_group_name == ""
      error_message = "A region joining an existing DNS zone is a region group member: set region_group_member = true, and apply terraform/region-group to point the shared wildcard domain at the group's front door."
    }
  }

  depends_on = [azurerm_dns_zone.catalyst]
}

# This region's own name, bypassing the group's front door.
#
# Only a group member gets one. A standalone region is reached at the wildcard
# above, which already points at its own address; a member's wildcard points at
# the group's front door, so without this name there is no way to reach one
# named region. Asking a named region whether it accepts writes is what every
# failover check does.
#
# An exact name beats the wildcard in Azure DNS, and the wildcard certificate
# covers it. It points straight at the region's address rather than at anything
# health-aware: a passive region has to keep resolving, because answering 503
# there is the whole point of asking it.
#
# It lives here rather than in the region-group stack so that stack needs
# nothing from a member region but its load balancer frontend. That is what lets
# the group's front door be re-applied while a member region is unreachable.
resource "azurerm_dns_a_record" "catalyst_region" {
  count = local.dns_enabled && var.region_group_member ? 1 : 0

  name                = var.cluster_name
  zone_name           = var.region_ingress_endpoint
  resource_group_name = local.dns_zone_resource_group
  ttl                 = 60
  records             = [azurerm_public_ip.gateway.ip_address]
  tags                = var.tags

  depends_on = [azurerm_dns_zone.catalyst]
}

output "region_endpoint" {
  description = "This region's own hostname, which reaches it whether or not it is the member of its group taking traffic. Null outside a region group, where the wildcard domain already resolves to this region."
  value       = try(azurerm_dns_a_record.catalyst_region[0].fqdn, null)
}

output "region_ingress_endpoint" {
  description = "The ingress endpoint to be used as argument to `diagrid region update` command"
  value       = local.region_ingress_endpoint
}

output "region_wildcard_domain" {
  description = "The region's wildcard domain"
  value       = local.wildcard_domain
}

output "dns_zone_resource_group_name" {
  description = "Resource group holding the DNS zone with this region's records. The second region of a region group passes this as its own `dns_zone_resource_group_name`, so both regions share one wildcard domain."
  value       = local.dns_enabled ? local.dns_zone_resource_group : null
}

output "dns_zone_name_servers" {
  description = "Name servers of the DNS zone this region created, to delegate the domain to. Null when this region joined an existing zone, which already has its own delegation."
  value       = try(azurerm_dns_zone.catalyst[0].name_servers, null)
}
