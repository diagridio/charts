# Terraform utils
.PHONY: init plan apply destroy validate fmt clean help

# Default target
.DEFAULT_GOAL := help

# Variables
TF_VAR_FILE ?= terraform/terraform.tfvars

# Keeping the peering at false until we create the connection.
ENABLE_PEERING ?= "false"
PEER_VPC_ID ?= 
PEER_VPC_CIDR ?= 

# Bastion host configuration
ENABLE_BASTION ?= "true"
BASTION_KEY_NAME ?= 
BASTION_ALLOWED_CIDR ?= "0.0.0.0/0"
REGION ?= "us-west-2"
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
	@echo "Variables:"
	@echo "  TF_VAR_FILE           - Terraform variables file (default: terraform/terraform.tfvars)"
	@echo "  ENABLE_PEERING        - Whether to enable VPC peering (default: false)"
	@echo "  PEER_VPC_ID           - ID of the VPC to peer with (required if ENABLE_PEERING=true)"
	@echo "  PEER_VPC_CIDR         - CIDR block of the VPC to peer with (required if ENABLE_PEERING=true)"
	@echo "  ENABLE_BASTION        - Whether to deploy a bastion host (default: true)"
	@echo "  BASTION_KEY_NAME      - SSH key name for the bastion host (optional, will be auto-generated if not provided)"
	@echo "  BASTION_ALLOWED_CIDR  - CIDR blocks allowed to SSH to the bastion host (default: 0.0.0.0/0)"
	@echo "  REGION                - AWS region to deploy resources (default: us-west-2)"
	@echo ""
	@echo "Example usage:"
	@echo "  make plan PEER_VPC_ID=vpc-12345 PEER_VPC_CIDR=172.31.0.0/16"
	@echo "  make plan ENABLE_PEERING=false"
	@echo "  make apply BASTION_ALLOWED_CIDR=10.0.0.0/8"
	@echo "  make apply BASTION_KEY_NAME=my-existing-key BASTION_ALLOWED_CIDR=10.0.0.0/8"
	@echo "  make plan ENABLE_BASTION=false"

# Initialize terraform
init:
	cd terraform && terraform init

# Plan terraform changes
plan:
	@if [ "$(ENABLE_PEERING)" = "true" ] && ([ -z "$(PEER_VPC_ID)" ] || [ -z "$(PEER_VPC_CIDR)" ]); then \
		echo "Error: When ENABLE_PEERING=true, PEER_VPC_ID and PEER_VPC_CIDR must be provided"; \
		echo "Example: make plan PEER_VPC_ID=vpc-12345 PEER_VPC_CIDR=172.31.0.0/16"; \
		exit 1; \
	fi
	# BASTION_KEY_NAME is now optional and will be auto-generated if not provided
	cd terraform && terraform plan \
		-var="enable_peering=$(ENABLE_PEERING)" \
		-var="peer_vpc_id=$(PEER_VPC_ID)" \
		-var="peer_vpc_cidr=$(PEER_VPC_CIDR)" \
		-var="enable_bastion=$(ENABLE_BASTION)" \
		-var="bastion_key_name=$(BASTION_KEY_NAME)" \
		-var="bastion_allowed_cidr=$(BASTION_ALLOWED_CIDR)" \
		-var="aws_region=$(REGION)" \
		-var="region_ingress_endpoint=$(REGION_INGRESS_ENDPOINT)" \
		$(if $(wildcard $(TF_VAR_FILE)),-var-file=../$(TF_VAR_FILE),)

# Apply terraform changes
apply:
	@if [ "$(ENABLE_PEERING)" = "true" ] && ([ -z "$(PEER_VPC_ID)" ] || [ -z "$(PEER_VPC_CIDR)" ]); then \
		echo "Error: When ENABLE_PEERING=true, PEER_VPC_ID and PEER_VPC_CIDR must be provided"; \
		echo "Example: make apply PEER_VPC_ID=vpc-12345 PEER_VPC_CIDR=172.31.0.0/16"; \
		exit 1; \
	fi
	# BASTION_KEY_NAME is now optional and will be auto-generated if not provided
	cd terraform && terraform apply \
		-var="enable_peering=$(ENABLE_PEERING)" \
		-var="peer_vpc_id=$(PEER_VPC_ID)" \
		-var="peer_vpc_cidr=$(PEER_VPC_CIDR)" \
		-var="enable_bastion=$(ENABLE_BASTION)" \
		-var="bastion_key_name=$(BASTION_KEY_NAME)" \
		-var="bastion_allowed_cidr=$(BASTION_ALLOWED_CIDR)" \
		-var="aws_region=$(REGION)" \
		-var="region_ingress_endpoint=$(REGION_INGRESS_ENDPOINT)" \
		$(if $(wildcard $(TF_VAR_FILE)),-var-file=../$(TF_VAR_FILE),)

# Destroy terraform resources
destroy:
	@if [ "$(ENABLE_PEERING)" = "true" ] && ([ -z "$(PEER_VPC_ID)" ] || [ -z "$(PEER_VPC_CIDR)" ]); then \
		echo "Error: When ENABLE_PEERING=true, PEER_VPC_ID and PEER_VPC_CIDR must be provided"; \
		echo "Example: make destroy PEER_VPC_ID=vpc-12345 PEER_VPC_CIDR=172.31.0.0/16"; \
		exit 1; \
	fi
	# BASTION_KEY_NAME is now optional and will be auto-generated if not provided
	cd terraform && terraform destroy \
		-var="enable_peering=$(ENABLE_PEERING)" \
		-var="peer_vpc_id=$(PEER_VPC_ID)" \
		-var="peer_vpc_cidr=$(PEER_VPC_CIDR)" \
		-var="enable_bastion=$(ENABLE_BASTION)" \
		-var="bastion_key_name=$(BASTION_KEY_NAME)" \
		-var="bastion_allowed_cidr=$(BASTION_ALLOWED_CIDR)" \
		-var="aws_region=$(REGION)" \
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
