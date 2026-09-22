output "accelerator_dns_name" {
  description = "DNS name of the accelerator. The wildcard record aliases this; you do not normally use it directly."
  value       = aws_globalaccelerator_accelerator.catalyst.dns_name
}

output "accelerator_ip_addresses" {
  description = "The accelerator's static anycast addresses. They do not change when the group fails over, so they are what to allowlist in a firewall."
  value       = flatten([for set in aws_globalaccelerator_accelerator.catalyst.ip_sets : set.ip_addresses])
}

# The records themselves belong to each member region's own state, which holds
# the Load Balancer they alias. Naming them here saves reading two more states
# to find out what to curl.
output "region_endpoints" {
  description = "Per-region hostnames that bypass the accelerator and reach one named region, whether or not it is the one taking traffic. Each region creates its own record; this only names them."
  value = {
    primary   = "${var.primary_cluster_name}.${var.region_ingress_endpoint}"
    secondary = "${var.secondary_cluster_name}.${var.region_ingress_endpoint}"
  }
}

output "gateway_load_balancers" {
  description = "The gateway Load Balancer registered with the accelerator for each region, whether it was given or discovered by tag"
  value = {
    primary   = local.primary_nlb_arn
    secondary = local.secondary_nlb_arn
  }
}

output "traffic_dial_percentages" {
  description = "What share of traffic each region is allowed to take. 0 means the region is drained: healthy, but taking no new connections."
  value = {
    primary   = aws_globalaccelerator_endpoint_group.primary.traffic_dial_percentage
    secondary = aws_globalaccelerator_endpoint_group.secondary.traffic_dial_percentage
  }
}
