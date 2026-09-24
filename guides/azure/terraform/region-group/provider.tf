terraform {
  # Cross-variable validation (the drain flags against each other) landed in 1.9.
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.6"
    }
  }
}

# One provider, unlike the AWS guide's three.
#
# The AWS provider is scoped to a region, so that stack configures one per
# member region plus one for the global services, and has to suppress the
# credential checks each of them would otherwise make against a region that may
# be unreachable. azurerm is scoped to a subscription instead and takes the
# region as an argument, so a single provider reaches both members and the front
# door, and there is nothing to suppress.
#
# It does mean both member regions have to be in this subscription. Two
# subscriptions would need an aliased provider per member and an explicit
# provider on each region's lookup below.
provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  features {}
}
