# A jumpbox for reaching what has no public endpoint.
#
# On AWS the bastion exists because the EKS API server is private. Here it is
# the PostgreSQL servers that cannot be reached from outside: Flexible Server
# with private networking is injected into the delegated subnet and has no
# public endpoint at all, whatever the firewall says. The AKS API server is
# public in this guide — restrict it with api_server_authorized_ip_ranges rather
# than by putting it behind this host.
#
# Off by default, because a region that never needs a psql session never needs
# the host.
resource "azurerm_public_ip" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name                = "${var.cluster_name}-bastion-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name                = "${var.cluster_name}-bastion-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.bastion[0].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.bastion[0].id
  }
}

resource "azurerm_linux_virtual_machine" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name                = "${var.cluster_name}-bastion"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  size                = var.bastion_instance_type
  admin_username      = var.bastion_admin_username
  network_interface_ids = [
    azurerm_network_interface.bastion[0].id,
  ]
  tags = var.tags

  # The role assignments below are granted to this identity, so the host reaches
  # the cluster as itself rather than through a copied kubeconfig — and a host
  # that is torn down takes its access with it.
  identity {
    type = "SystemAssigned"
  }

  # Azure Linux VMs have no password login, so the key is not optional the way
  # the AWS guide's is.
  admin_ssh_key {
    username   = var.bastion_admin_username
    public_key = var.bastion_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  lifecycle {
    precondition {
      condition     = var.bastion_ssh_public_key != ""
      error_message = "enable_bastion needs bastion_ssh_public_key: an Azure Linux VM has no password login, so a host built without a key cannot be reached at all."
    }
  }
}

resource "azurerm_role_assignment" "bastion_cluster_user" {
  count = var.enable_bastion ? 1 : 0

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azurerm_linux_virtual_machine.bastion[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "bastion_cluster_admin" {
  count = var.enable_bastion ? 1 : 0

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = azurerm_linux_virtual_machine.bastion[0].identity[0].principal_id
}

output "bastion_public_ip" {
  description = "Public address of the bastion host, null when enable_bastion is false"
  value       = try(azurerm_public_ip.bastion[0].ip_address, null)
}
