# Terraform utils
.PHONY: init plan apply destroy validate fmt clean help \
	group-init group-plan group-apply group-destroy group-output

# Default target
.DEFAULT_GOAL := help

# Variables
TF_VAR_FILE ?= terraform/terraform.tfvars

# The region group front door is a second root with its own state, applied once
# for the group after both regions are up. Its variables live in
# terraform/region-group/terraform.tfvars, which terraform reads by itself.
GROUP_DIR := terraform/region-group

# Set TF_PLAN_OUT to save the plan to a file instead of only printing it, so it
# can be inspected and then applied unchanged. failover.sh plans through this
# target for that reason: what it checks is exactly what it applies.
TF_PLAN_OUT ?=

# Extra arguments for `terraform plan`. failover.sh passes -replace here when it
# rebuilds a database as a replica, which Azure can only do by replacing it.
TF_PLAN_ARGS ?=

# Peering is off until the connection is wanted. The other region of a region
# group does not need it.
ENABLE_PEERING ?= "false"
PEER_VNET_ID ?=

# Bastion host configuration. Off by default: it exists to reach the PostgreSQL
# servers, which have no public endpoint, and a region that never needs a psql
# session never needs the host.
ENABLE_BASTION ?= "false"
LOCATION ?= "westus2"
REGION_INGRESS_ENDPOINT ?= ""

# Help target
help:
	@echo "Terraform Makefile Targets:"
	@echo "  init        - Initialize terraform"
	@echo "  plan        - Plan terraform changes"
	@echo "  apply       - Apply terraform changes"
	@echo "  destroy     - Destroy terraform resources"
	@echo "  validate    - Validate terraform configuration"
	@echo "  fmt         - Format terraform files"
	@echo "  clean       - Clean terraform files"
	@echo ""
	@echo "Region group front door (terraform/region-group, one state per group):"
	@echo "  group-init    - Initialize the region group terraform"
	@echo "  group-plan    - Plan the region group front door"
	@echo "  group-apply   - Apply the region group front door"
	@echo "  group-destroy - Destroy the region group front door"
	@echo "  group-output  - Read an output of the region group front door"
	@echo ""
	@echo "Moving the writer between the two members of a region group:"
	@echo "  ./failover.sh status   - Which member is the writer, and whether it is drained"
	@echo "  ./failover.sh promote  - Promote this region's databases (failover)"
	@echo "  ./failover.sh follow   - Rebuild them as replicas (failback)"
	@echo ""
	@echo "Variables:"
	@echo "  TF_VAR_FILE           - Terraform variables file (default: terraform/terraform.tfvars)"
	@echo "  TF_PLAN_OUT           - Save the plan to this file so it can be inspected and applied unchanged"
	@echo "  TF_PLAN_ARGS          - Extra arguments for terraform plan, e.g. -replace=azurerm_postgresql_flexible_server.postgresql"
	@echo "  ENABLE_PEERING        - Whether to peer with an external virtual network (default: false)"
	@echo "  PEER_VNET_ID          - Resource ID of the virtual network to peer with (required if ENABLE_PEERING=true)"
	@echo "  ENABLE_BASTION        - Whether to deploy a bastion host (default: false)"
	@echo "  LOCATION              - Azure region to deploy resources (default: westus2)"
	@echo "  REGION_INGRESS_ENDPOINT - The region's wildcard domain, without the leading star"
	@echo ""
	@echo "Example usage:"
	@echo "  make plan LOCATION=westus2 REGION_INGRESS_ENDPOINT=catalyst.example.com"
	@echo "  make apply ENABLE_PEERING=true PEER_VNET_ID=/subscriptions/.../virtualNetworks/corp"
	@echo "  make apply ENABLE_BASTION=true"

# Initialize terraform
init:
	cd terraform && terraform init

# Plan terraform changes
plan:
	@if [ "$(ENABLE_PEERING)" = "true" ] && [ -z "$(PEER_VNET_ID)" ]; then \
		echo "Error: When ENABLE_PEERING=true, PEER_VNET_ID must be provided"; \
		echo "Example: make plan PEER_VNET_ID=/subscriptions/.../virtualNetworks/corp"; \
		exit 1; \
	fi
	cd terraform && terraform plan \
		-var="enable_peering=$(ENABLE_PEERING)" \
		-var="peer_vnet_id=$(PEER_VNET_ID)" \
		-var="enable_bastion=$(ENABLE_BASTION)" \
		-var="location=$(LOCATION)" \
		-var="region_ingress_endpoint=$(REGION_INGRESS_ENDPOINT)" \
		$(if $(wildcard $(TF_VAR_FILE)),-var-file=../$(TF_VAR_FILE),) \
		$(if $(TF_PLAN_OUT),-out=$(TF_PLAN_OUT),) \
		$(TF_PLAN_ARGS)

# Apply terraform changes
apply:
	@if [ "$(ENABLE_PEERING)" = "true" ] && [ -z "$(PEER_VNET_ID)" ]; then \
		echo "Error: When ENABLE_PEERING=true, PEER_VNET_ID must be provided"; \
		echo "Example: make apply PEER_VNET_ID=/subscriptions/.../virtualNetworks/corp"; \
		exit 1; \
	fi
	cd terraform && terraform apply \
		-var="enable_peering=$(ENABLE_PEERING)" \
		-var="peer_vnet_id=$(PEER_VNET_ID)" \
		-var="enable_bastion=$(ENABLE_BASTION)" \
		-var="location=$(LOCATION)" \
		-var="region_ingress_endpoint=$(REGION_INGRESS_ENDPOINT)" \
		$(if $(wildcard $(TF_VAR_FILE)),-var-file=../$(TF_VAR_FILE),)

# Destroy terraform resources
destroy:
	@if [ "$(ENABLE_PEERING)" = "true" ] && [ -z "$(PEER_VNET_ID)" ]; then \
		echo "Error: When ENABLE_PEERING=true, PEER_VNET_ID must be provided"; \
		echo "Example: make destroy PEER_VNET_ID=/subscriptions/.../virtualNetworks/corp"; \
		exit 1; \
	fi
	cd terraform && terraform destroy \
		-var="enable_peering=$(ENABLE_PEERING)" \
		-var="peer_vnet_id=$(PEER_VNET_ID)" \
		-var="enable_bastion=$(ENABLE_BASTION)" \
		-var="location=$(LOCATION)" \
		-var="region_ingress_endpoint=$(REGION_INGRESS_ENDPOINT)" \
		$(if $(wildcard $(TF_VAR_FILE)),-var-file=../$(TF_VAR_FILE),)

output:
	@cd terraform && terraform output $(filter-out $@,$(MAKECMDGOALS)) | tr -d '"'

%:
	@:

# Validate terraform configuration
validate:
	cd terraform && terraform validate

# Format terraform files
fmt:
	cd terraform && terraform fmt

# Clean terraform files
clean:
	rm -rf terraform/.terraform
	rm -f terraform/.terraform.lock.hcl

# Region group front door
#
# Variables go in terraform/region-group/terraform.tfvars; terraform reads that
# file on its own, so these targets pass nothing.
group-init:
	cd $(GROUP_DIR) && terraform init

group-plan:
	cd $(GROUP_DIR) && terraform plan

group-apply:
	cd $(GROUP_DIR) && terraform apply

group-destroy:
	cd $(GROUP_DIR) && terraform destroy

group-output:
	@cd $(GROUP_DIR) && terraform output $(filter-out $@,$(MAKECMDGOALS)) | tr -d '"'
