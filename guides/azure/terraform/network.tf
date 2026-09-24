# One resource group holds the region. AKS adds a second of its own — the node
# resource group — which holds the VMSS, the disks and the load balancer the
# cluster creates for a Service of type LoadBalancer. That second group is
# managed by AKS, not by this configuration; aks.tf names it as an output
# because the gateway's load balancer lives there and the region group's front
# door has to be pointed at it.
resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = var.location
  tags     = var.tags
}

locals {
  resource_group_name = var.resource_group_name != "" ? var.resource_group_name : "${var.cluster_name}-rg"
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.cluster_name}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "${var.cluster_name}-aks-subnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.aks_subnet_cidr]
}

# Flexible Server with private networking is injected into a subnet delegated to
# it, and Azure gives it exclusive use: nothing else can be placed in this
# subnet, and the delegation cannot be added to a subnet that already holds
# anything. Hence a subnet of its own rather than sharing the AKS one.
resource "azurerm_subnet" "database" {
  name                 = "${var.cluster_name}-db-subnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.database_subnet_cidr]

  # Declared because Azure adds it: creating a Flexible Server in this subnet
  # attaches a Microsoft.Storage endpoint, and a subnet that does not name it
  # plans to remove it on every run after the first. That is more than noise —
  # failover.sh refuses a promotion whose plan touches anything outside the
  # Flexible Server family, so a subnet that never converges is a writer that
  # can never be moved.
  service_endpoint {
    service = "Microsoft.Storage"
  }

  delegation {
    name = "postgresql"

    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

resource "azurerm_subnet" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name                 = "${var.cluster_name}-bastion-subnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.bastion_subnet_cidr]
}

# The AKS node subnet's security group.
#
# Azure default rules already allow everything inside the virtual network, and
# the load balancer's health probes, so there is nothing to add for the
# cluster's own traffic. They also deny everything inbound from the internet,
# and that includes the gateway: AKS writes an allow rule for a Service of type
# LoadBalancer, but into the security group in its own node resource group, not
# into this one. Both are evaluated, so without the rule below the gateway's
# address answers nothing — not a client, and not the region group's front
# door, which passes the client's own address through.
#
# The destination is any address, not the gateway's: traffic the front door
# relays arrives addressed to the front door's global address, which this
# stack is applied before and cannot know. The nodes have no public addresses
# of their own, so the only internet traffic that can reach them on 443 is
# what one of those two load balancers forwards.
resource "azurerm_network_security_group" "aks" {
  name                = "${var.cluster_name}-aks-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  security_rule {
    name                       = "gateway-https"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

resource "azurerm_network_security_group" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name                = "${var.cluster_name}-bastion-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  security_rule {
    name                       = "ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.bastion_allowed_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "bastion" {
  count = var.enable_bastion ? 1 : 0

  subnet_id                 = azurerm_subnet.bastion[0].id
  network_security_group_id = azurerm_network_security_group.bastion[0].id
}

output "resource_group_name" {
  description = "Resource group holding this region. Not the group the cluster's own load balancer is in — that is aks_node_resource_group."
  value       = azurerm_resource_group.this.name
}

output "vnet_id" {
  description = "Resource ID of this region's virtual network. The other region of a group peers with it, and the teardown in the deployment guide checks it is empty before destroying anything."
  value       = azurerm_virtual_network.this.id
}
