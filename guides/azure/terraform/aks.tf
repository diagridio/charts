# The AKS cluster.
#
# Two settings here are not ordinary defaults, and a region group depends on
# both:
#
#   load_balancer_sku = "standard"  A cross-region load balancer only accepts
#                                   Standard load balancer frontends in its
#                                   backend pool. The Basic SKU cannot be a
#                                   member of a region group at all.
#
#   outbound_type     = "loadBalancer"  The cluster's own Standard load balancer
#                                   carries egress as well as ingress. That is
#                                   AKS's default and it is what guarantees the
#                                   load balancer the gateway Service is
#                                   programmed onto exists and has a public
#                                   frontend. There is no NAT gateway here for
#                                   that reason; if a deployment outgrows the
#                                   load balancer's SNAT ports, attach one to
#                                   the node subnet rather than changing this.
resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.cluster_version
  tags                = var.tags

  # Workload identity, so the Catalyst pods reach Azure APIs as themselves
  # rather than through a secret. Both flags are needed: the OIDC issuer is what
  # Entra ID federates against, and workload_identity_enabled installs the
  # mutating webhook that projects the token into the pod.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  role_based_access_control_enabled = true

  default_node_pool {
    name                 = "workers"
    vm_size              = var.node_instance_type
    vnet_subnet_id       = azurerm_subnet.aks.id
    auto_scaling_enabled = true
    node_count           = var.node_desired_capacity
    min_count            = var.node_min_capacity
    max_count            = var.node_max_capacity
    zones                = var.availability_zones
    tags                 = var.tags

    # AKS sets this block itself on any pool that does not declare it, so a
    # configuration that stays silent about it never converges: the create
    # succeeds and every plan afterwards proposes to remove it again. That is
    # not only noise — ./failover.sh refuses a promotion whose plan touches the
    # cluster, so a stack that always shows a cluster change is a stack whose
    # writer cannot be moved. Declared here with AKS's own defaults, which
    # makes it an operator's dial rather than permanent drift.
    upgrade_settings {
      max_surge                     = "10%"
      drain_timeout_in_minutes      = 0
      node_soak_duration_in_minutes = 0
    }
  }

  # Manual, not Auto: the node pool above is the cluster's capacity, sized by
  # the tier files in tiers/. Node autoprovisioning would size it from pending
  # pods instead and ignore those figures.
  node_provisioning_profile {
    mode = "Manual"
  }

  identity {
    type = "SystemAssigned"
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = var.tenant_id
  }

  api_server_access_profile {
    authorized_ip_ranges = var.api_server_authorized_ip_ranges
  }

  network_profile {
    network_plugin    = "azure"
    load_balancer_sku = "standard"
    outbound_type     = "loadBalancer"
    # Explicit, because AKS's own default service range is 10.0.0.0/16 and so is
    # this guide's default virtual network. With Azure CNI the pods take
    # virtual network addresses, so an overlapping service range is refused at
    # create time.
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip
  }

  lifecycle {
    # The autoscaler owns the node count once the cluster is running, so
    # re-applying must not drag it back to node_desired_capacity. The floor and
    # the ceiling stay managed here.
    ignore_changes = [default_node_pool[0].node_count]
  }
}

# The public address the region is reached at.
#
# It is created here rather than left to AKS so that it is static, known before
# the Catalyst agent is installed, and destroyed with this region rather than
# with the cluster. The gateway Service is pointed at it by name, with
#
#   service.beta.kubernetes.io/azure-load-balancer-resource-group: <resource_group_name>
#   service.beta.kubernetes.io/azure-pip-name: <gateway_public_ip_name>
#
# and AKS attaches it to the cluster's load balancer as a frontend. Everything
# downstream — this region's DNS record, and the region group's front door —
# then has a fixed thing to point at instead of an address that changes every
# time the Service is recreated.
#
# Standard SKU and static allocation, both required: a Basic or dynamic address
# cannot be a Standard load balancer frontend, and only a Standard frontend can
# join a cross-region load balancer's backend pool.
resource "azurerm_public_ip" "gateway" {
  name                = "${var.cluster_name}-gateway-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  sku_tier            = "Regional"
  zones               = var.availability_zones
  tags                = var.tags
}

# AKS attaches the address above to its own load balancer, which means its
# cluster identity has to be allowed to manage an address in a resource group it
# does not own. Scoped to the one address rather than the resource group.
resource "azurerm_role_assignment" "aks_gateway_public_ip" {
  scope                = azurerm_public_ip.gateway.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.this.identity[0].principal_id
}

# Cluster access. Azure RBAC is on, so membership is granted with role
# assignments rather than in an aad-pod-identity ConfigMap: the Cluster User
# role is what lets a principal fetch a kubeconfig at all, and the RBAC roles
# are what that kubeconfig can then do.
resource "azurerm_role_assignment" "cluster_user" {
  for_each = toset(concat(var.aks_admin_principal_ids, var.aks_readonly_principal_ids))

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = each.key
}

resource "azurerm_role_assignment" "cluster_admin" {
  for_each = toset(var.aks_admin_principal_ids)

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.key
}

resource "azurerm_role_assignment" "cluster_reader" {
  for_each = toset(var.aks_readonly_principal_ids)

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Reader"
  principal_id         = each.key
}

output "aks_cluster_name" {
  description = "AKS cluster name"
  value       = azurerm_kubernetes_cluster.this.name
}

output "aks_cluster_region" {
  description = "Azure region the cluster runs in"
  value       = var.location
}

output "aks_node_resource_group" {
  description = "The resource group AKS manages on the cluster's behalf. The load balancer the gateway Service is programmed onto lives here, which is what the region group's front door needs: pass it as that stack's primary_node_resource_group or secondary_node_resource_group."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "aks_oidc_issuer_url" {
  description = "The cluster's OIDC issuer, to federate an Entra ID workload identity against"
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "gateway_public_ip_name" {
  description = "Name of the public address the gateway Service must claim. Goes on the Service as service.beta.kubernetes.io/azure-pip-name, together with azure-load-balancer-resource-group set to resource_group_name."
  value       = azurerm_public_ip.gateway.name
}

output "gateway_public_ip_id" {
  description = "Resource ID of this region's gateway address. The region group's front door takes it as primary_gateway_public_ip_id or secondary_gateway_public_ip_id: it is how that stack picks this region's frontend out of the cluster load balancer's, without depending on what AKS happened to name it."
  value       = azurerm_public_ip.gateway.id
}

output "gateway_public_ip_address" {
  description = "The address itself. This region's DNS record points at it, and it is static for the life of the region."
  value       = azurerm_public_ip.gateway.ip_address
}
