variable "name" {
  description = "Name for the accelerator and the prefix for the resources this stack creates"
  type        = string
  default     = "catalyst-region-group"
}

variable "tags" {
  description = "Tags to apply to all AWS resources"
  type        = map(string)
  default     = {}
}

variable "region_ingress_endpoint" {
  description = "The wildcard domain both member regions serve, without the leading star. Identical to the region_ingress_endpoint each region was applied with."
  type        = string
}

variable "route53_zone_id" {
  description = "ID of the hosted zone for region_ingress_endpoint. The first region created it; take it from that region's route53_zone_id output."
  type        = string
}

variable "primary_aws_region" {
  description = "AWS region of the first member region"
  type        = string
}

variable "primary_cluster_name" {
  description = "cluster_name of the first member region, used to find its gateway Load Balancer"
  type        = string
}

variable "secondary_aws_region" {
  description = "AWS region of the second member region"
  type        = string
}

variable "secondary_cluster_name" {
  description = "cluster_name of the second member region, used to find its gateway Load Balancer"
  type        = string
}

# Giving a member's Load Balancer ARN instead of discovering it is what makes
# this stack appliable while that member region is unreachable — which is when
# the traffic dial below is worth reaching for. Record both at setup, from each
# region's gateway_nlb_arn output, rather than when you need them.
variable "primary_gateway_lb_arn" {
  description = "ARN of the first region's gateway Load Balancer, from its gateway_nlb_arn output. Left empty, it is discovered by tag, which reads that region's account and therefore needs it to be reachable."
  type        = string
  default     = ""
}

variable "secondary_gateway_lb_arn" {
  description = "The same for the second region. Set both and this stack reads nothing from either member region."
  type        = string
  default     = ""
}

# Draining a region is a planned failover: the accelerator stops sending new
# connections to it while its endpoint is still healthy, so writes can be
# stopped before the database is promoted rather than by promoting it.
variable "primary_traffic_dial_percentage" {
  description = "Percentage of the traffic the accelerator would otherwise send to the first region that it actually sends. Set to 0 to drain that region before a planned failover, and back to 100 afterwards."
  type        = number
  default     = 100

  validation {
    condition     = var.primary_traffic_dial_percentage >= 0 && var.primary_traffic_dial_percentage <= 100
    error_message = "primary_traffic_dial_percentage must be between 0 and 100."
  }
}

variable "secondary_traffic_dial_percentage" {
  description = "The same dial for the second region. Leave both at 100 and the accelerator sends every connection to whichever region its Load Balancer reports healthy, which is the region that accepts writes."
  type        = number
  default     = 100

  validation {
    condition     = var.secondary_traffic_dial_percentage >= 0 && var.secondary_traffic_dial_percentage <= 100
    error_message = "secondary_traffic_dial_percentage must be between 0 and 100."
  }
}

variable "listener_port" {
  description = "TCP port the accelerator listens on and forwards to the gateway Load Balancers"
  type        = number
  default     = 443
}

variable "client_affinity" {
  description = "SOURCE_IP keeps a client's connections on one region for as long as that region is healthy. NONE spreads them by 5-tuple."
  type        = string
  default     = "SOURCE_IP"

  validation {
    condition     = contains(["NONE", "SOURCE_IP"], var.client_affinity)
    error_message = "client_affinity must be NONE or SOURCE_IP."
  }
}
