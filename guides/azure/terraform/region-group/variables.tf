variable "subscription_id" {
  description = "Azure subscription holding both member regions and the front door. Null falls through to ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "tenant_id" {
  description = "Azure AD tenant the subscription belongs to"
  type        = string
  default     = null
}

variable "name" {
  description = "Name for the front door and the prefix for the resources this stack creates"
  type        = string
  default     = "catalyst-region-group"
}

variable "tags" {
  description = "Tags to apply to all Azure resources"
  type        = map(string)
  default     = {}
}

# A cross-region load balancer and its address can only be created in one of
# Azure's home regions. This does NOT constrain where the member regions are:
# the home region holds the front door object and takes no part in routing, and
# Azure documents that traffic is unaffected if it goes down. Any two regions
# can be a pair; only this one address has to live in the list below.
variable "location" {
  description = "Azure region to create the front door in. Must be a cross-region load balancer home region; it holds the global address and takes no part in routing, so it does not have to be either member's region."
  type        = string
  default     = "westus"

  validation {
    condition = contains([
      "centralus",
      "eastasia",
      "eastus2",
      "northeurope",
      "southeastasia",
      "uksouth",
      "usgovvirginia",
      "westeurope",
      "westus",
      "chinanorth2",
    ], var.location)
    error_message = "A global load balancer can only be created in a cross-region load balancer home region: centralus, eastasia, eastus2, northeurope, southeastasia, uksouth, usgovvirginia, westeurope, westus, chinanorth2. The member regions are not restricted."
  }
}

variable "resource_group_name" {
  description = "Resource group to create for the front door. Empty names it after `name`."
  type        = string
  default     = ""
}

variable "region_ingress_endpoint" {
  description = "The wildcard domain both member regions serve, without the leading star. Identical to the region_ingress_endpoint each region was applied with."
  type        = string
}

variable "dns_zone_resource_group_name" {
  description = "Resource group of the DNS zone for region_ingress_endpoint. The first region created it; take it from that region's dns_zone_resource_group_name output."
  type        = string
}

variable "primary_cluster_name" {
  description = "cluster_name of the first member region, used to name it in this stack's outputs"
  type        = string
}

variable "secondary_cluster_name" {
  description = "cluster_name of the second member region"
  type        = string
}

# Finding a member's frontend means reading the cluster's own load balancer in
# the resource group AKS manages for it, and matching the frontend that carries
# the address that region's terraform created. Both values come from that
# region's outputs: aks_node_resource_group and gateway_public_ip_id.
variable "primary_node_resource_group" {
  description = "The first region's aks_node_resource_group output, which holds the load balancer its gateway Service is programmed onto. Ignored when primary_gateway_frontend_ip_configuration_id is given."
  type        = string
  default     = ""
}

variable "primary_gateway_public_ip_id" {
  description = "The first region's gateway_public_ip_id output. It picks that region's frontend out of the cluster load balancer's, rather than relying on what AKS named it. Ignored when primary_gateway_frontend_ip_configuration_id is given."
  type        = string
  default     = ""
}

variable "secondary_node_resource_group" {
  description = "The same for the second member region"
  type        = string
  default     = ""
}

variable "secondary_gateway_public_ip_id" {
  description = "The same for the second member region"
  type        = string
  default     = ""
}

# Giving a member's frontend directly instead of discovering it is what makes
# this stack appliable while that member region is unreachable — which is when
# draining it below is worth reaching for. Record both at setup, from this
# stack's gateway_frontend_ip_configurations output after a successful apply,
# rather than when you need them.
variable "primary_gateway_frontend_ip_configuration_id" {
  description = "Resource ID of the first region's gateway frontend on its cluster load balancer. Left empty, it is looked up, which reads that region's resource group and therefore needs it to be reachable."
  type        = string
  default     = ""
}

variable "secondary_gateway_frontend_ip_configuration_id" {
  description = "The same for the second region. Set both and this stack reads nothing from either member region."
  type        = string
  default     = ""
}

# Draining a region is a planned failover: the front door stops sending it
# connections while it is still healthy, so writes can be stopped before the
# database is promoted rather than by promoting it.
#
# It is coarser than the AWS guide's traffic dial, which is a percentage. A
# cross-region load balancer has no equivalent — a region is in the backend pool
# or it is not — so this removes the region from the pool and puts it back.
# Ordering is what the runbook actually depends on, and that is preserved: stop
# traffic reaching the region, THEN promote.
variable "primary_drained" {
  description = "Take the first region out of the front door's backend pool. Set it before a planned failover away from that region, and back to false afterwards. All-or-nothing, unlike the AWS guide's percentage dial."
  type        = bool
  default     = false
}

variable "secondary_drained" {
  description = "The same for the second region. Leave both false and the front door sends every connection to whichever region its load balancer reports healthy, which is the region that accepts writes."
  type        = bool
  default     = false

  validation {
    condition     = !(var.primary_drained && var.secondary_drained)
    error_message = "Draining both regions empties the front door's backend pool and takes the group offline. Drain the one you are failing away from."
  }
}

variable "listener_port" {
  description = "TCP port the front door listens on and forwards to the regional load balancers. It must match the port the regional rule fronts, which is the port the gateway serves."
  type        = number
  default     = 443
}

variable "load_distribution" {
  description = "SourceIP keeps a client's connections on one region for as long as that region is healthy. Default spreads them by 5-tuple."
  type        = string
  default     = "SourceIP"

  validation {
    condition     = contains(["Default", "SourceIP", "SourceIPProtocol"], var.load_distribution)
    error_message = "load_distribution must be Default, SourceIP or SourceIPProtocol."
  }
}
