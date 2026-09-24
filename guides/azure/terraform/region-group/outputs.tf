output "front_door_ip_address" {
  description = "The front door's static anycast address. It does not change when the group fails over, so it is what to allowlist in a firewall. The wildcard record resolves to it."
  value       = azurerm_public_ip.front_door.ip_address
}

output "front_door_load_balancer_id" {
  description = "Resource ID of the group's global load balancer"
  value       = azurerm_lb.front_door.id
}

# The records themselves belong to each member region's own state, which holds
# the address they point at. Naming them here saves reading two more states to
# find out what to curl.
output "region_endpoints" {
  description = "Per-region hostnames that bypass the front door and reach one named region, whether or not it is the one taking traffic. Each region creates its own record; this only names them."
  value = {
    primary   = "${var.primary_cluster_name}.${var.region_ingress_endpoint}"
    secondary = "${var.secondary_cluster_name}.${var.region_ingress_endpoint}"
  }
}

output "gateway_frontend_ip_configurations" {
  description = "The gateway frontend registered for each region, whether it was given or discovered. Record both and pass them back as primary_gateway_frontend_ip_configuration_id and secondary_gateway_frontend_ip_configuration_id: with both set, this stack can be re-applied while a member region is unreachable. Null for a region that is drained, which is not in the pool."
  value = {
    primary   = local.primary_in_pool ? local.primary_frontend_id : null
    secondary = local.secondary_in_pool ? local.secondary_frontend_id : null
  }
}

output "drained_regions" {
  description = "Which members are out of the front door's backend pool. A drained region is healthy but takes no connections, and the group cannot fail over to it while it is."
  value = {
    primary   = var.primary_drained
    secondary = var.secondary_drained
  }
}
