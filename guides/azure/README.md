# Diagrid Catalyst Private: Azure Deployment Guide

> **Note:** This guide is for demonstration purposes and should not be used in production.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [What is Catalyst Private?](#what-is-catalyst-private)
3. [Azure Architecture Overview](#azure-architecture-overview)
4. [Catalyst Private Workflow Support](#catalyst-private-workflow-support)
5. [Installation Steps](#installation-steps)
   - [1. Create a Catalyst Region](#1-create-a-catalyst-region)
   - [2. Login to Azure](#2-login-to-azure)
   - [3. Deploy Azure Resources](#3-deploy-azure-resources)
   - [4. Connect to the Azure VM](#4-connect-to-the-azure-vm)
   - [5. Prepare Azure VM](#5-prepare-azure-vm)
   - [6. Install PostgreSQL for Dapr Workflow](#6-install-postgresql-for-dapr-workflow)
   - [7. Configure and Install Catalyst](#7-configure-and-install-catalyst)
   - [8. Get Started](#8-get-started)
6. [Configuration Options](#configuration-options)
7. [Limitations](#limitations)
8. [References](#references)

---

## Prerequisites

### Required Tools

- **Azure CLI** (v2.45.0+): For managing Azure resources and authentication
- **Diagrid CLI** (v0.12.0+): For managing Catalyst regions and projects
- **AWS CLI** (v2.0+): Required for OCI registry login to pull Catalyst images from AWS ECR
- **Helm** (v3.12.0+): For deploying Catalyst to Kubernetes
- **kubectl** (v1.28+): For interacting with the Kubernetes cluster
- **jq** (v1.6+): For JSON parsing in shell scripts

### Azure Requirements

- **Valid Azure Subscription**: With owner permissions for resource creation
- **Available Quotas**: Ensure sufficient vCPU and memory quotas for AKS and VM resources
- **SSH Keys**: For VM access (generate with `ssh-keygen -t rsa -b 4096` if needed)

### Environment Variables

- **JOIN_TOKEN**: Generated from Diagrid CLI for region registration
- **API_KEY**: Diagrid API key for CLI authentication (24-hour expiry for demo)

---

## What is Catalyst Private?

Catalyst Private is a self-hosted deployment of Diagrid Catalyst, running in your own environment. It provides a centralized Dapr control plane and application identity system that can be used to build enterprise-grade Dapr systems across polyglot compute platforms. Specifically, Catalyst is purpose-built to support Dapr Workflow development and operations.

This document covers how to deploy Catalyst Private within your Azure Virtual Network, with all traffic routed through a centralized firewall. It also details how to configure your Catalyst deployment with support for Workflow visualization, which requires a PostgreSQL instance.

---

## Azure Architecture Overview

The Azure setup in this guide provisions a secure, production-ready environment for Catalyst Private. While customization options are available, this baseline configuration provides a complete, working deployment. The installation guide will create and configure the following:

- **Resource Group**: Logical container for all resources related to Catalyst Private
- **Virtual Network (VNet)**: Isolated network space with a custom IP range (default: `10.42.0.0/16`)
- **Subnets**:
  - **Primary Subnet**: For AKS and the management VM (default: `10.42.1.0/24`)
  - **Firewall Subnet**: Dedicated subnet for Azure Firewall (default: `10.42.2.0/24`, must be named `AzureFirewallSubnet`)
- **Azure Firewall**:
  - Centralized network security with a public IP for controlled ingress/egress
  - All outbound traffic from the AKS cluster and VM is routed through the firewall for inspection and control
  - **Firewall Network Rules**:
    - **NTP (UDP 123)**: Allows time synchronization for all resources
    - **DNS (UDP 53)**: Allows DNS queries to Azure DNS servers
    - **Service Tags**: Allows access to Azure Container Registry, Microsoft Container Registry, Azure Active Directory, Azure Monitor, etc.
    - **API TCP/UDP**: Allows TCP (9000) and UDP (1194) for Azure API and VPN access
  - **Firewall Application Rules**:
    - Allows HTTP/HTTPS access to a curated list of FQDNs required for:
      - Diagrid services (`*.diagrid.io`)
      - Kubernetes image and package downloads
      - GitHub and container registries (Azure, AWS, GCP, Docker)
      - Ubuntu and Linux package repositories
      - Azure management and monitoring endpoints
      - Helm and Bitnami chart repositories
      - Other required cloud and dev services
    - Allows AKS-specific FQDN tags for Kubernetes operations
    - Application rule to allow the management VM to access the private AKS API server via the firewall
  - **DNAT Rule for SSH Access**:
    - Destination NAT rule on the firewall allows SSH (port 22) from your client IP to the VM's private IP via the firewall's public IP
    - Ensures secure, auditable access to the management VM
- **Route Table**:
  - All traffic from the primary subnet is routed to the firewall (using a default route `0.0.0.0/0` with next hop as the firewall's private IP)
- **AKS Cluster**:
  - Private Kubernetes cluster (API server not publicly accessible from the internet)
  - 3 nodes by default, deployed in the primary subnet
  - User Defined Routing: All outbound traffic from AKS nodes is forced through the firewall
  - Managed Identity enabled for secure authentication
- **Management VM**:
  - Ubuntu VM deployed in the primary subnet, no public IP (accessed via firewall DNAT rule)
  - Used as a jumpbox for cluster and resource management
  - Managed Identity and contributor role assigned

This architecture closely aligns with the [AKS Baseline Architecture](https://learn.microsoft.com/en-us/azure/architecture/reference-architectures/containers/aks/aks-baseline.png), ensuring all compute resources (AKS and VM) are isolated in a private network, with all ingress and egress traffic controlled and inspected by Azure Firewall. Only required ports and FQDNs are allowed, and SSH access is tightly controlled via DNAT rules.

---

## Catalyst Private Workflow Support

At its core, Catalyst Private hosts the **Dapr Workflow API**, providing a robust foundation for building long-running, stateful workflows with built-in fault tolerance, scalability, and visualization.

In Catalyst Private, PostgreSQL is required to store the data that powers workflow visualization. You can choose to use the same instance to store the workflow engine state or bring your own workflow state store. In this guide, we will use a PostgreSQL instance hosted within AKS to power both the workflow state storage and the visualization.

- **Workflow Visualization**: Enables the Catalyst console to display workflow diagrams, execution paths, and real-time workflow status
- **Workflow State Management**: Stores workflow execution state, including task status, variables, and execution history

### Configuration Details

If you choose to enable support for Workflows in Catalyst Private, the following will be configured as part of the setup below:

- **PostgreSQL Configuration**:

  - Creates a dedicated `catalyst` database for workflow data using a PostgreSQL Helm Chart
  - Sets up default credentials (`postgres/postgres`) for initial setup
  - Configures internal Kubernetes service discovery via `postgres-postgresql.postgres.svc.cluster.local`

- **Catalyst Integration**: The Catalyst Private Helm values are configured to use PostgreSQL as the external state store:
  - `default_managed_state_store_type: postgresql-shared-external` enables PostgreSQL integration
  - Connection string parameters specify the Kubernetes service endpoint and database credentials

> **Note:** To visualize the workflows run on Catalyst Private through the Catalyst console, you will need to ensure the appropriate networking rules are configured to allow access to the Catalyst UI from your installation.

If you choose to forgo the workflow setup, you can still use Catalyst Private with the other supported Dapr APIs like service invocation, pubsub, state management, etc.

---

## Installation Steps

### 1. Create a Catalyst Region

Use the Diagrid CLI to create a new region and obtain a join token:

```bash
diagrid login

export PRIVATE_REGION="azure-region"
export AZURE_API_KEY="azure-key"

# Create a new region and capture the join token
export JOIN_TOKEN=$(diagrid region create $PRIVATE_REGION --ingress "http://*.10.42.1.180.nip.io:8080" | jq -r .joinToken)

# Create an API key for CLI use
# Note: This API key expires after 24 hours. If you plan to continue using this demo environment, remove the duration
export API_KEY=$(diagrid apikey create --name $AZURE_API_KEY --role cra.diagrid:editor --duration 86400 | jq -r .token)
```

### 2. Login to Azure

```bash
az login
```

### 3. Deploy Azure Resources

Review and run the provided install script `install.sh` to provision the Azure architecture described above:

```bash
chmod +x ./install.sh
./install.sh
```

The script will automatically:

- Create the resource group, VNet, subnets, firewall, AKS cluster, and management VM
- Set up routing and security rules
- Prepare the environment for Catalyst deployment

You do not need to manually configure any of the above resources; the script handles all provisioning and configuration as described in the architecture overview.

### 4. Connect to the Azure VM

Open a terminal and set up an SSH connection to the Azure VM:

```bash
# Connect to the Azure VM via SSH using the connection script generated as part of the installation
chmod +x ./connect.sh
./connect.sh
```

> **Note:** From this point on, commands should be executed on the Azure VM.

### 5. Prepare Azure VM

```bash
# Install CLI tooling and dependencies to VM
chmod +x "$HOME/setup.sh"
"$HOME/setup.sh"
rm "$HOME/setup.sh"

# Source the environment
source .env

# Login to Diagrid CLI
diagrid login --api-key="$API_KEY"
```

### 6. Install PostgreSQL for Dapr Workflow

To use Dapr Workflow with Catalyst Private, deploy a PostgreSQL instance to the AKS cluster. This step is optional.

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm install postgres bitnami/postgresql \
  --set auth.postgresPassword=postgres \
  --set auth.database=catalyst \
  --create-namespace \
  --namespace postgres
```

### 7. Configure and Install Catalyst

Create a Helm values file:

**With PostgreSQL:**

```yaml
agent:
  config:
    project:
      default_managed_state_store_type: postgresql-shared-external
      external_postgresql:
        enabled: true
        auth_type: connectionString
        namespace: postgres
        connection_string_host: postgres-postgresql.postgres.svc.cluster.local
        connection_string_port: 5432
        connection_string_username: postgres
        connection_string_password: postgres
        connection_string_database: catalyst
gateway:
  envoy:
    service:
      type: LoadBalancer
    podAnnotations:
      service.beta.kubernetes.io/azure-load-balancer-internal: "true"
      service.beta.kubernetes.io/azure-load-balancer-ipv4: 10.42.1.180
```

**Without PostgreSQL:**

```yaml
agent:
  config:
    project:
      default_managed_state_store_type: postgresql-shared-disabled
gateway:
  envoy:
    service:
      type: LoadBalancer
    podAnnotations:
      service.beta.kubernetes.io/azure-load-balancer-internal: "true"
      service.beta.kubernetes.io/azure-load-balancer-ipv4: 10.42.1.180
```

Install Catalyst:

```bash
helm install catalyst oci://public.ecr.aws/diagrid/catalyst \
   -n cra-agent \
   --create-namespace \
   -f catalyst-values.yaml \
   --set join_token="${JOIN_TOKEN}" \
   --version 0.34.0-rc.1
```

Verify the installation by waiting for all pods to be ready:

```bash
kubectl -n cra-agent wait --for=condition=ready pod --all --timeout=5m
```

### 8. Get Started

Create a Catalyst project in your newly deployed private region:

```bash
# Create the project
export PROJECT_NAME="azure-project"

diagrid project create $PROJECT_NAME --region $PRIVATE_REGION

# Use the project
diagrid project use $PROJECT_NAME
```

Create [App IDs](https://docs.diagrid.io/catalyst/concepts/appids) in your new project to test resource creation and connectivity:

```bash
diagrid appid create app1
diagrid appid create app2

# Wait until the appids are ready
diagrid appid list

# See your Dapr runtime instances running in Kubernetes
kubectl get po -A | grep prj
```

Open a new SSH connection to the Azure VM to start a listener:

```bash
# Connect a new SSH session to the Azure VM
./connect.sh

# Start a listener for app1, wait until a log line like:
# ✅ Connected App ID "app1" to http://localhost:61016 ⚡️
diagrid listen -a app1
```

Send messages between your App IDs:

```bash
# From the original SSH session, call app1 from app2
diagrid call invoke get app1.hello -a app2

# You will now see the requests being received on your app1 listener
# ...
# {
#   "method": "GET",
#   "url": "/hello"
# }
```

This proves that you are able to use [Dapr's service invocation API](https://docs.dapr.io/developing-applications/building-blocks/service-invocation/service-invocation-overview/) by calling your App ID over a private IP. In this scenario, we have used the Diagrid CLI to act as both the sending and receiving applications. To read more about this approach, see [Test Catalyst APIs using the Diagrid CLI](https://docs.diagrid.io/catalyst/how-to-guides/test-apis-directly).

To continue testing, refer to [local development docs](https://docs.diagrid.io/catalyst/how-to-guides/develop-locally) for insights on building and deploying your own apps.

---

## Configuration Options

### Network Configuration

- **VNet Address Space**: Customizable via `ADDRESS_PREFIX` (default: 10.42.0.0/16)
- **Subnet Ranges**: Configurable via `SUBNET_PREFIX` (default: 10.42.1.0/24)
- **Load Balancer IP**: Set via `LOADBALANCER_IPV4` (default: 10.42.1.180)

### Compute Resources

- **AKS Node Count**: Default 3 nodes, configurable in install.sh
- **VM Size**: Default Standard_B2s (2 vCPU, 4GB), change via `VM_SIZE`
- **AKS Node Pool**: Configurable VM sizes and autoscaling

### Security Customization

- **Firewall Rules**: Add custom FQDN allowlists for additional services
- **Network Rules**: Configure additional ports/protocols as needed
- **Access Control**: Modify SSH access rules and IP restrictions

### Workflow Configuration

- **PostgreSQL**: Optional, enables workflow visualization and state management
- **External State Stores**: Support for custom PostgreSQL instances
- **Database Credentials**: Configurable via Helm values

---

## Limitations

- **Secrets Support**: Catalyst Private supports storing secrets in AWS Secrets Manager or Kubernetes Secrets. Azure Key Vault support is on the roadmap.

---

## References

- [Diagrid CLI Reference](https://docs.diagrid.io/catalyst/references/cli-reference/intro)
- [Dapr Workflow API](https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-overview/)
- [Dapr Service Invocation](https://docs.dapr.io/developing-applications/building-blocks/service-invocation/service-invocation-overview/)

---
