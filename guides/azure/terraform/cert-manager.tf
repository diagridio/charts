# cert-manager's identity, for the DNS-01 challenge against Azure DNS.
#
# The gateway serves a wildcard certificate for the region's domain, and
# cert-manager issues it by solving an ACME DNS-01 challenge: it writes a TXT
# record into the region's DNS zone, Let's Encrypt reads it back, and the
# certificate lands in the `cert-wildcard` secret the gateway is pointed at.
#
# Writing that record needs an Azure identity holding DNS Zone Contributor on
# the zone. The cluster is already built to hand one over without a secret —
# oidc_issuer_enabled and workload_identity_enabled are both on in aks.tf — so
# a user-assigned identity federated to cert-manager's service account is the
# Azure counterpart of the AWS guide's cert-manager IAM role, and nothing
# long-lived is stored in the cluster.
#
# The second region of a region group writes into the FIRST region's zone,
# because both members serve one wildcard domain and only one of them created
# it. So the zone is looked up rather than referenced whenever this region
# joined an existing one.

locals {
  # cert-manager's own service account, as its Helm chart installs it. The
  # federated credential has to name it exactly: Entra ID matches the subject
  # of the projected token, not the pod.
  cert_manager_namespace       = "cert-manager"
  cert_manager_service_account = "cert-manager"
}

resource "azurerm_user_assigned_identity" "cert_manager" {
  count = local.dns_enabled ? 1 : 0

  name                = "${var.cluster_name}-cert-manager"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

# The zone this region writes challenge records into: its own when it created
# one, the other region's when it joined one.
data "azurerm_dns_zone" "cert_manager" {
  count = local.dns_enabled && var.dns_zone_resource_group_name != "" ? 1 : 0

  name                = var.region_ingress_endpoint
  resource_group_name = var.dns_zone_resource_group_name
}

locals {
  cert_manager_dns_zone_id = (local.dns_enabled
    ? (var.dns_zone_resource_group_name != ""
      ? one(data.azurerm_dns_zone.cert_manager[*].id)
    : one(azurerm_dns_zone.catalyst[*].id))
  : null)
}

# Scoped to the one zone rather than to the resource group holding it: the
# second region of a group is granted on the first region's zone, and nothing
# else in that region's resource group is its business.
resource "azurerm_role_assignment" "cert_manager_dns" {
  count = local.dns_enabled ? 1 : 0

  scope                = local.cert_manager_dns_zone_id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.cert_manager[0].principal_id
}

resource "azurerm_federated_identity_credential" "cert_manager" {
  count = local.dns_enabled ? 1 : 0

  name                      = "cert-manager"
  user_assigned_identity_id = azurerm_user_assigned_identity.cert_manager[0].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject                   = "system:serviceaccount:${local.cert_manager_namespace}:${local.cert_manager_service_account}"
}

output "cert_manager_identity_client_id" {
  description = "Client ID of the identity cert-manager solves the DNS-01 challenge as. It goes in two places: the azure.workload.identity/client-id annotation on cert-manager's service account, and managedIdentity.clientID on the ClusterIssuer's azureDNS solver."
  value       = try(azurerm_user_assigned_identity.cert_manager[0].client_id, null)
}

output "cert_manager_dns_zone_resource_group_name" {
  description = "Resource group of the DNS zone cert-manager writes challenge records into. The ClusterIssuer's azureDNS solver takes it as resourceGroupName. It is this region's own resource group in the region that created the zone, and the other region's in the one that joined it."
  value       = local.dns_enabled ? local.dns_zone_resource_group : null
}
