#!/bin/bash

# =============================================================================
# AZURE CATALYST PRIVATE INFRASTRUCTURE SETUP SCRIPT
# =============================================================================
# 
# OVERVIEW:
# This script creates a complete Azure infrastructure for running Catalyst Private,
# including:
# 
# 1. NETWORK INFRASTRUCTURE:
#    - Resource Group: Container for all Azure resources
#    - Virtual Network (VNet): Private network with custom IP ranges
#    - Subnets: Separate network segments for AKS and Firewall
#    - Route Tables: Control traffic flow through the firewall
# 
# 2. SECURITY COMPONENTS:
#    - Azure Firewall: Centralized network security with public IP
#    - Network Rules: Allow specific protocols and ports (DNS, NTP, API access)
#    - Application Rules: Allow specific FQDNs for container registries, 
#      package managers, and cloud services
#    - DNAT Rules: Enable SSH access to VM through firewall
# 
# 3. COMPUTE RESOURCES:
#    - AKS Cluster: Private Kubernetes cluster with 3 nodes
#    - Ubuntu VM: Management VM for accessing the cluster
# 
# 4. NETWORKING FEATURES:
#    - User Defined Routing: All outbound traffic routes through firewall
#    - Private Cluster: AKS API server is not publicly accessible
#    - Managed Identity: Secure authentication without secrets
# 
# PREREQUISITES:
# - Azure CLI installed and authenticated
# - kubectl installed
# - SSH key pair generated
# - JOIN_TOKEN and API_KEY environment variables set
# 
# =============================================================================

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

# Check if Azure CLI is installed
if ! command -v az &> /dev/null
then
    echo "Azure CLI could not be found"
    echo "please install Azure CLI by running: brew install azure-cli"
    exit
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null
then
    echo "kubectl could not be found"
    echo "please install kubectl by running: brew install kubectl"
    exit
fi

# Verify required environment variables are set
if [ -z "$JOIN_TOKEN" ]; then
  echo "JOIN_TOKEN is not set. Please set it before running this script."
  exit 1
fi
if [ -z "$API_KEY" ]; then
  echo "API_KEY is not set. Please set it before running this script."
  exit 1
fi

# =============================================================================
# CONFIGURATION VARIABLES
# =============================================================================

# Default values that can be overridden via environment variables
RESOURCE_GROUP="${RESOURCE_GROUP:-catalyst-private-final}"  # Container for all resources
LOCATION="${LOCATION:-eastus}"                              # Azure region
VNET_NAME="${VNET_NAME:-catalyst-vnet}"                     # Virtual network name
SUBNET_NAME="${SUBNET_NAME:-catalyst-subnet}"               # Main subnet for AKS/VM
LOADBALANCER_IPV4="${LOADBALANCER_IPV4:-10.42.2.180}"      # Load balancer IP (unused)
ADDRESS_PREFIX="${ADDRESS_PREFIX:-10.42.0.0/16}"           # VNet address space
SUBNET_PREFIX="${SUBNET_PREFIX:-10.42.1.0/24}"             # Main subnet range
AKS_NAME="${AKS_NAME:-catalyst-cluster}"                    # AKS cluster name
VM_NAME="${VM_NAME:-catalyst-vm}"                           # Management VM name
VM_SIZE="${VM_SIZE:-Standard_B2s}"                          # VM size (2 vCPU, 4GB RAM)
ADMIN_USERNAME="${ADMIN_USERNAME:-azureuser}"               # VM admin username
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"          # SSH private key path

# Verify SSH key pair exists
if [[ ! -f "$SSH_KEY_PATH" || ! -f "$SSH_KEY_PATH.pub" ]]; then
  echo "SSH key not found at $SSH_KEY_PATH. Please generate an SSH key pair and place the public key at this location."
  exit 1
fi


# Create copy of setup.sh for VM deployment
cp setup.sh __setup.sh

# Export environment variables for Catalyst Private
echo "echo \"export JOIN_TOKEN=${JOIN_TOKEN}\" > .env" >> __setup.sh
echo "echo \"export API_KEY=${API_KEY}\" >> .env" >> __setup.sh

# Set proper permissions on SSH key
chmod 400 "$SSH_KEY_PATH"
echo "🔑 Using SSH key from $SSH_KEY_PATH"

echo "📦 Ensuring Azure resources..."

# =============================================================================
# RESOURCE GROUP CREATION
# =============================================================================

# Create a Resource Group if it doesn't exist
# Resource Groups are logical containers that hold related Azure resources
if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
  echo "> Creating resource group $RESOURCE_GROUP..."
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

  echo "✅ Resource group $RESOURCE_GROUP created."
else
  echo "✅ Resource group $RESOURCE_GROUP already exists."
fi

# =============================================================================
# VIRTUAL NETWORK AND SUBNET CREATION
# =============================================================================

# Create a VNet and Subnet if they don't exist
# VNet provides isolated network space for Azure resources
if ! az network vnet show --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" &>/dev/null; then

  echo "> Creating VNet $VNET_NAME..."
  az network vnet create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VNET_NAME" \
    --address-prefixes "$ADDRESS_PREFIX" \
    --subnet-name "$SUBNET_NAME" \
    --subnet-prefix "$SUBNET_PREFIX"

  echo "✅ VNet $VNET_NAME created."
else
  echo "✅ VNet $VNET_NAME already exists."
  # Create subnet separately if VNet exists but subnet doesn't
  if ! az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$SUBNET_NAME" &>/dev/null; then
    echo "> Creating Subnet $SUBNET_NAME..."
    az network vnet subnet create \
      --resource-group "$RESOURCE_GROUP" \
      --vnet-name "$VNET_NAME" \
      --name "$SUBNET_NAME" \
      --address-prefix "$SUBNET_PREFIX"

    echo "✅ Subnet $SUBNET_NAME created."
  else
    echo "✅ Subnet $SUBNET_NAME already exists."
  fi
fi

# =============================================================================
# AZURE FIREWALL SETUP
# =============================================================================

# Firewall configuration variables
FIREWALL_NAME="catalyst-firewall"
FIREWALL_SUBNET_NAME="AzureFirewallSubnet"  # Special subnet name required for Azure Firewall
FIREWALL_SUBNET_PREFIX="10.42.2.0/24"       # Dedicated subnet for firewall

# Azure Firewall serializes all write operations on a single firewall: starting a
# new change (rule collection, IP config, etc.) while the previous one is still
# settling fails with "AnotherOperationInProgress". fw_run waits until the
# firewall is idle (provisioningState=Succeeded) before issuing the wrapped
# command, and retries that command if it still hits the transient busy error.
# Usage: fw_run az network firewall <...> create <...>
fw_run() {
  local attempt=1
  local max_attempts=20
  local rc pid tmp waited secs

  while true; do
    # Wait (up to ~10 min) for any in-flight firewall operation to finish before
    # starting a new one. Azure serializes all writes to a single firewall.
    waited=0
    while [ "$(az network firewall show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$FIREWALL_NAME" \
        --query provisioningState -o tsv 2>/dev/null)" != "Succeeded" ]; do
      [ "$waited" -eq 0 ] && echo "  ⏳ Firewall busy with another operation; waiting for it to finish..."
      [ "$waited" -ge 600 ] && break
      sleep 15
      waited=$((waited + 15))
    done

    # Run the command in the background with a heartbeat. Azure Firewall rule and
    # IP-config changes legitimately take several minutes each, and az prints no
    # progress when its output is captured — without the heartbeat it looks hung.
    tmp=$(mktemp)
    "$@" >"$tmp" 2>&1 &
    pid=$!
    secs=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 20
      secs=$((secs + 20))
      printf '  … still applying (%dm%02ds elapsed, Azure Firewall changes are slow)\n' "$((secs / 60))" "$((secs % 60))"
    done
    wait "$pid" && rc=0 || rc=$?

    if [ "$rc" -eq 0 ]; then
      rm -f "$tmp"
      return 0
    fi

    if [ "$attempt" -lt "$max_attempts" ] && grep -qi "AnotherOperationInProgress" "$tmp"; then
      echo "  ⏳ Firewall busy (AnotherOperationInProgress); retry ${attempt}/${max_attempts} in 20s..."
      rm -f "$tmp"
      sleep 20
      attempt=$((attempt + 1))
      continue
    fi

    # Non-transient failure or retries exhausted: surface the captured error and
    # let 'set -e' abort the script.
    cat "$tmp" >&2
    rm -f "$tmp"
    return "$rc"
  done
}

# Create the Firewall subnet if it doesn't exist
# Azure Firewall requires a dedicated subnet named "AzureFirewallSubnet"
if ! az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$FIREWALL_SUBNET_NAME" &>/dev/null; then

  echo "> Creating Firewall subnet $FIREWALL_SUBNET_NAME..."
  az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$FIREWALL_SUBNET_NAME" \
    --address-prefix "$FIREWALL_SUBNET_PREFIX"

  echo "✅ Firewall subnet $FIREWALL_SUBNET_NAME created."
else
  echo "✅ Firewall subnet $FIREWALL_SUBNET_NAME already exists."
fi

# Create a public IP for the Firewall FIRST (before creating the firewall)
# Public IP allows the firewall to be accessible from the internet
if ! az network public-ip show --resource-group "$RESOURCE_GROUP" --name "$FIREWALL_NAME" &>/dev/null; then

  echo "> Creating Firewall public IP..."
  az network public-ip create \
    --name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku Standard \
    --allocation-method Static
  echo "✅ Firewall public IP created."
else
  echo "✅ Firewall public IP $FIREWALL_NAME already exists."
fi

# Create Azure Firewall if it doesn't exist
# Azure Firewall provides centralized network security and traffic filtering
if ! az network firewall show --resource-group "$RESOURCE_GROUP" --name "$FIREWALL_NAME" &>/dev/null; then

  echo "> Creating Azure Firewall $FIREWALL_NAME..."

  # Create the firewall resource itself. The IP configuration (which attaches the
  # public IP and allocates the private IP from AzureFirewallSubnet) is created
  # separately below — newer azure-firewall CLI versions no longer auto-create it
  # from --vnet-name/--public-ip on `firewall create`.
  az network firewall create \
    --name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION"

  echo "✅ Azure Firewall $FIREWALL_NAME created."
else
  echo "✅ Azure Firewall $FIREWALL_NAME already exists."
fi

# Ensure the firewall has an IP configuration.
# Without an IP configuration the firewall has no private IP, which breaks the
# route-table next-hop configuration below (MissingNextHopIpAddress). This runs
# for both newly-created and pre-existing firewalls so it self-heals firewalls
# that were created before this step existed.
FW_IPCONFIG_NAME="${FW_IPCONFIG_NAME:-${FIREWALL_NAME}-ipconfig}"
if [ -z "$(az network firewall ip-config list \
    --resource-group "$RESOURCE_GROUP" \
    --firewall-name "$FIREWALL_NAME" \
    --query "[0].name" -o tsv 2>/dev/null)" ]; then

  echo "> Creating firewall IP configuration $FW_IPCONFIG_NAME..."
  fw_run az network firewall ip-config create \
    --resource-group "$RESOURCE_GROUP" \
    --firewall-name "$FIREWALL_NAME" \
    --name "$FW_IPCONFIG_NAME" \
    --public-ip-address "$FIREWALL_NAME" \
    --vnet-name "$VNET_NAME"

  echo "✅ Firewall IP configuration $FW_IPCONFIG_NAME created."
else
  echo "✅ Firewall IP configuration already exists."
fi

# =============================================================================
# FIREWALL CONFIGURATION
# =============================================================================

# Get firewall IP addresses for routing configuration
FW_PUBLIC_IP=$(az network public-ip show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$FIREWALL_NAME" \
  --query ipAddress -o tsv)

# Get Firewall's private IP for routing
# This IP is used as the next-hop for traffic routing
FW_PRIVATE_IP=$(az network firewall show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$FIREWALL_NAME" \
  --query "ipConfigurations[0].privateIPAddress" -o tsv)

# Fail fast with an actionable message rather than letting the empty value
# surface later as a cryptic "MissingNextHopIpAddress" on route creation.
if [ -z "$FW_PRIVATE_IP" ]; then
  echo "❌ Firewall $FIREWALL_NAME has no private IP — its IP configuration is missing or still provisioning."
  echo "   Inspect with: az network firewall show -g $RESOURCE_GROUP -n $FIREWALL_NAME --query ipConfigurations -o json"
  exit 1
fi

echo "✅ Firewall $FIREWALL_NAME is configured with public IP: $FW_PUBLIC_IP"
echo "✅ Firewall private IP for routing: $FW_PRIVATE_IP"

# =============================================================================
# ROUTE TABLE CONFIGURATION
# =============================================================================

# Create a route table to route AKS outbound traffic via the firewall
# This ensures all internet-bound traffic goes through the firewall for inspection
FW_RT_NAME="catalyst-firewall-route-table"
if ! az network route-table show --resource-group "$RESOURCE_GROUP" --name "$FW_RT_NAME" &>/dev/null; then

  echo "> Creating route table $FW_RT_NAME..."
  az network route-table create \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --name "$FW_RT_NAME"

  echo "✅ Route table $FW_RT_NAME created."
else
  echo "✅ Route table $FW_RT_NAME already exists."
fi

# Create a default route to forward traffic to the firewall if it doesn't exist
# This route sends all traffic (0.0.0.0/0) to the firewall for inspection
if ! az network route-table route show --resource-group "$RESOURCE_GROUP" --route-table-name "$FW_RT_NAME" --name "DefaultRoute" &>/dev/null; then

  echo "> Creating default route to forward traffic to the firewall..."
  az network route-table route create \
    --resource-group "$RESOURCE_GROUP" \
    --route-table-name "$FW_RT_NAME" \
    --name "DefaultRoute" \
    --address-prefix "0.0.0.0/0" \
    --next-hop-type "VirtualAppliance" \
    --next-hop-ip-address "$FW_PRIVATE_IP"

  echo "✅ Default route created."
else
  echo "✅ Default route already exists."
fi

# Associate the route table with the subnet if it doesn't exist
# This applies the routing rules to all resources in the subnet
if ! az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$SUBNET_NAME" --query routeTable.id -o tsv | grep -q "$FW_RT_NAME"; then

  echo "> Associating $FW_RT_NAME with subnet $SUBNET_NAME..."
  az network vnet subnet update \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --route-table "$FW_RT_NAME"

  echo "✅ Route table $FW_RT_NAME associated with subnet $SUBNET_NAME."
else
  echo "✅ Route table $FW_RT_NAME already associated with subnet $SUBNET_NAME."
fi

# =============================================================================
# FIREWALL NETWORK RULES
# =============================================================================

# Create time network rule collection if it doesn't exist
# Allows NTP (port 123) for time synchronization
if ! az network firewall network-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowTimeCollectionGroup" 2>/dev/null \
    | grep -q "AllowNetworkAzure"; then

  echo "> Configuring network rules (time) for the firewall..."
  fw_run az network firewall network-rule create \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowTimeCollectionGroup" \
    --name "AllowNetworkAzure" \
    --protocols "UDP" \
    --priority 100 \
    --action "Allow" \
    --source-addresses "*" \
    --destination-addresses "*" \
    --destination-ports 123

  echo "✅ Network rules (time) configured for the firewall."
else
  echo "✅ Network rules (time) already exist for the firewall."
fi

# Create dns network rule collection if it doesn't exist
# Allows DNS queries (port 53) to Azure DNS servers
if ! az network firewall network-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowDNSCollectionGroup" 2>/dev/null \
    | grep -q "AllowNetworkAzure"; then

  echo "> Configuring network rules (dns) for the firewall..."
  fw_run az network firewall network-rule create \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowDNSCollectionGroup" \
    --name "AllowNetworkAzure" \
    --protocols "UDP" \
    --priority 101 \
    --action "Allow" \
    --source-addresses "*" \
    --destination-addresses "AzureCloud.$LOCATION" \
    --destination-ports 53

  echo "✅ Network rules (dns) configured for the firewall."
else
  echo "✅ Network rules (dns) already exist for the firewall."
fi

# Create service tags network rule collection if it doesn't exist
# Allows access to Azure service tags for container registries and monitoring
if ! az network firewall network-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowServiceTagsCollectionGroup" 2>/dev/null \
    | grep -q "AllowNetworkAzure"; then

  echo "> Configuring network rules (servicetags) for the firewall..."
  fw_run az network firewall network-rule create \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowServiceTagsCollectionGroup" \
    --name "AllowNetworkAzure" \
    --protocols "Any" \
    --priority 102 \
    --action "Allow" \
    --source-addresses "*" \
    --destination-addresses "AzureContainerRegistry" "MicrosoftContainerRegistry" "AzureActiveDirectory" "AzureMonitor" \
    --destination-ports 53

  echo "✅ Network rules (servicetags) configured for the firewall."
else
  echo "✅ Network rules (servicetags) already exist for the firewall."
fi

# Create network rule (ApiTCP) collection if it doesn't exist
# Allows TCP traffic on port 9000 for Azure API access
if ! az network firewall network-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowApiTcpCollectionGroup" 2>/dev/null \
    | grep -q "AllowNetworkAzure"; then

  echo "> Configuring network rules (apitcp) for the firewall..."
  fw_run az network firewall network-rule create \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowApiTcpCollectionGroup" \
    --name "AllowNetworkAzure" \
    --protocols "TCP" \
    --priority 103 \
    --action "Allow" \
    --source-addresses "*" \
    --destination-addresses "AzureCloud.$LOCATION" \
    --destination-ports 9000

  echo "✅ Network rules (apitcp) configured for the firewall."
else
  echo "✅ Network rules (apitcp) already exist for the firewall."
fi

# Create network rule (ApiUDP) collection if it doesn't exist
# Allows UDP traffic on port 1194 for VPN/API access
if ! az network firewall network-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowApiUdpCollectionGroup" 2>/dev/null \
    | grep -q "AllowNetworkAzure"; then

  echo "> Configuring network rules (apiudp) for the firewall..."
  fw_run az network firewall network-rule create \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowApiUdpCollectionGroup" \
    --name "AllowNetworkAzure" \
    --protocols "UDP" \
    --priority 104 \
    --action "Allow" \
    --source-addresses "*" \
    --destination-addresses "*" \
    --destination-ports 1194

  echo "✅ Network rules (apiudp) configured for the firewall."
else
  echo "✅ Network rules (apiudp) already exist for the firewall."
fi

# Create network rule (ServiceBus) collection if it doesn't exist
# Allows AMQP (TCP 5671) and HTTPS (443) egress to Azure Service Bus, used by the
# Dapr Service Bus pub/sub and binding components (pubsub.azure.servicebus.*). The
# Dapr SDK speaks AMQP over TCP 5671, which FQDN application rules can't filter, so
# this is a network rule against the regional ServiceBus service tag.
if ! az network firewall network-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowServiceBusCollectionGroup" 2>/dev/null \
    | grep -q "AllowNetworkAzure"; then

  echo "> Configuring network rules (servicebus) for the firewall..."
  fw_run az network firewall network-rule create \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowServiceBusCollectionGroup" \
    --name "AllowNetworkAzure" \
    --protocols "TCP" \
    --priority 105 \
    --action "Allow" \
    --source-addresses "*" \
    --destination-addresses "ServiceBus.$LOCATION" \
    --destination-ports 5671 443

  echo "✅ Network rules (servicebus) configured for the firewall."
else
  echo "✅ Network rules (servicebus) already exist for the firewall."
fi

# =============================================================================
# FIREWALL APPLICATION RULES
# =============================================================================

# Create application rule collection if it doesn't exist
# Allows HTTP/HTTPS access to specific FQDNs for container images, packages, etc.
if ! az network firewall application-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowApplicationRuleCollectionGroup" 2>/dev/null \
    | grep -q "AllowRuleApplication"; then

  echo "> Configuring application rules for the firewall..."
  TARGET_FQDNS=(
    # diagrid - Catalyst Private service endpoints (.io = prod, .dev = staging)
    "*.diagrid.io"
    "*.diagrid.dev"
    # kubernetes - K8s image downloads
    "*.dl.k8s.io"
    "dl.k8s.io"
    # github - Source code and container images
    "github.com"
    "api.github.com"
    "*.githubusercontent.com"
    "ghcr.io"
    # azure - Azure services and container registries
    "*.azure.com"
    "*.microsoftonline.com"
    "*.windows.net"
    "*.blob.storage.azure.net"
    "*.blob.core.windows.net"
    "mcr.microsoft.com"
    "acs-mirror.azureedge.net"
    "*.data.mcr.microsoft.com"
    "*.hcp.$LOCATION.azmk8s.io"
    "*.cdn.mscr.io"
    "management.azure.com"
    "login.microsoftonline.com"
    "packages.microsoft.com"
    "packages.aks.azure.com"
    "vault.azure.net"
    "*.vault.azure.net"
    "*.documents.azure.com"
    "*.ods.opinsights.azure.com"
    "*.oms.opinsights.azure.com"
    "dc.services.visualstudio.com"
    "*.monitoring.azure.com"
    "global.handler.control.monitor.azure.com"
    "*.ingest.monitor.azure.com"
    "*.metrics.ingest.monitor.azure.com"
    "*.handler.control.monitor.azure.com"
    "data.policy.core.windows.net"
    "store.policy.core.windows.net"
    "dc.services.visualstudio.com"
    "aks.ms"
    # aws - AWS container registries
    "*.amazonaws.com"
    "*.s3.amazonaws.com"
    "public.ecr.aws"
    # gcp - Google Cloud container registries
    "gcr.io"
    "storage.googleapis.com"
    "us-central1-docker.pkg.dev"
    # helm - Helm chart repositories
    "get.helm.sh"
    "charts.bitnami.com"
    "*.cloudfront.net"
    "repo.broadcom.com"
    # docker - Docker Hub and related services
    "*.docker.io"
    "*.docker.com"
    "registry-1.docker.io"
    "production.cloudflare.docker.com"
    # ngrok - Development tunneling service
    "*.ngrok.io"
    "*.ngrok.com"
    "*.ngrok-agent.com"
    "*.equinox.io"
    # ubuntu - Ubuntu package repositories and updates
    "archive.ubuntu.com"
    "security.ubuntu.com"
    "changelogs.ubuntu.com"
    "deb.debian.org"
    "ntp.ubuntu.com"
    'launchpad.net'
    'ppa.launchpad.net'
    'keyserver.ubuntu.com'
    'azure.archive.ubuntu.com'
    'download.opensuse.org'
    'snapcraft.io'
    'motd.ubuntu.com'
    'api.snapcraft.io'
  )

  fw_run az network firewall application-rule create \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowApplicationRuleCollectionGroup" \
    --name "AllowRuleApplication" \
    --protocols "https=443" "http=80" \
    --priority 100 \
    --action "Allow" \
    --source-addresses "*" \
    --target-fqdns "${TARGET_FQDNS[@]}"
  
  echo "✅ Application rules configured for the firewall."
else
  echo "✅ Application rules already exist for the firewall."
fi

# Create application rule (aks) collection if it doesn't exist
# Allows AKS-specific FQDN tags for Kubernetes operations
if ! az network firewall application-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowAKSCollectionGroup" 2>/dev/null \
    | grep -q "AllowRuleApplication"; then

  echo "> Configuring application rules (aks) for the firewall..."

  fw_run az network firewall application-rule create \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowAKSCollectionGroup" \
    --name "AllowRuleApplication" \
    --protocols "https=443" "http=80" \
    --priority 101 \
    --action "Allow" \
    --source-addresses "*" \
    --fqdn-tags "AzureKubernetesService"

  echo "✅ Application rules (aks) configured for the firewall."
else
  echo "✅ Application rules (aks) already exist for the firewall."
fi

# =============================================================================
# AKS CLUSTER CREATION
# =============================================================================

# Create AKS cluster if it doesn't exist
# Creates a private Kubernetes cluster with user-defined routing through firewall
if ! az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" &>/dev/null; then
  echo "> Creating AKS cluster $AKS_NAME..."
  
  # Get subnet ID for AKS deployment
  SUBNET_ID=$(az network vnet subnet show \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --query id -o tsv)
  
  # Create AKS with User Defined Routing for outbound traffic through Firewall
  az aks create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$AKS_NAME" \
    --load-balancer-sku standard \
    --network-plugin azure \
    --vnet-subnet-id "$SUBNET_ID" \
    --dns-service-ip 10.42.0.10 \
    --service-cidr 10.42.0.0/24 \
    --enable-managed-identity \
    --enable-private-cluster \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --node-count 3 \
    --ssh-key-value "$SSH_KEY_PATH.pub" \
    --outbound-type userDefinedRouting

  echo "✅ AKS cluster $AKS_NAME created."
else
  echo "✅ AKS cluster $AKS_NAME already exists."
fi

# Ensure OIDC issuer + workload identity are enabled (idempotent).
# The `az aks create` above sets these for new clusters; this `update` enables
# them on clusters created before these flags existed. Required for Azure AD
# Workload Identity (federated credentials) used by Dapr Azure components.
OIDC_ENABLED=$(az aks show -g "$RESOURCE_GROUP" -n "$AKS_NAME" --query "oidcIssuerProfile.enabled" -o tsv 2>/dev/null)
WI_ENABLED=$(az aks show -g "$RESOURCE_GROUP" -n "$AKS_NAME" --query "securityProfile.workloadIdentity.enabled" -o tsv 2>/dev/null)
if [ "$OIDC_ENABLED" != "true" ] || [ "$WI_ENABLED" != "true" ]; then
  echo "> Enabling OIDC issuer and workload identity on $AKS_NAME (this can take a few minutes)..."
  az aks update \
    --resource-group "$RESOURCE_GROUP" \
    --name "$AKS_NAME" \
    --enable-oidc-issuer \
    --enable-workload-identity
  echo "✅ OIDC issuer and workload identity enabled."
else
  echo "✅ OIDC issuer and workload identity already enabled."
fi

# Surface the OIDC issuer URL — needed to create federated identity credentials
# for Azure AD Workload Identity (e.g. `az ad app federated-credential create`).
OIDC_ISSUER_URL=$(az aks show -g "$RESOURCE_GROUP" -n "$AKS_NAME" --query "oidcIssuerProfile.issuerUrl" -o tsv 2>/dev/null)
echo "ℹ️  AKS OIDC issuer URL: $OIDC_ISSUER_URL"

# =============================================================================
# KUBERNETES API SERVER FIREWALL RULES
# =============================================================================

# Get the private FQDN of the Kubernetes API server
KUBE_API_SERVER_IP=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --query privateFqdn -o tsv)

# Add Kubernetes API server IP to the firewall rules if needed
# Allows access to the private AKS API server
if ! az network firewall application-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowKubernetesApiRuleCollectionGroup" 2>/dev/null | grep -q "$KUBE_API_SERVER_IP"; then

  echo "> Adding Kubernetes API server IP to firewall rules..."
  fw_run az network firewall application-rule create \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowKubernetesApiRuleCollectionGroup" \
    --priority 102 \
    --action "Allow" \
    --name "AllowRuleApplication" \
    --protocols "http=80" "https=443" \
    --target-fqdns "$KUBE_API_SERVER_IP"

  echo "✅ Kubernetes API server IP added to firewall rules."
else
  echo "✅ Kubernetes API server IP already exists in firewall rules."
fi

# =============================================================================
# MANAGEMENT VM CREATION
# =============================================================================

# Get Azure subscription ID for VM creation
AZURE_SUBSCRIPTION=$(az account show --query id -o tsv)

# Create a VM if it doesn't exist
# This VM serves as a management jumpbox for accessing the private AKS cluster
if ! az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" >/dev/null 2>&1; then
  # VM size availability depends on the region, subscription and current
  # capacity. Try the requested size first, then fall back through known-small
  # alternatives when Azure reports the size is unavailable (SkuNotAvailable).
  # `az vm create` is preflight-validated as a single ARM deployment, so a
  # SkuNotAvailable failure creates nothing and is safe to retry with another size.
  VM_SIZE_CANDIDATES=("$VM_SIZE" "Standard_B2as_v2" "Standard_B2s_v2" "Standard_D2s_v3" "Standard_D2as_v5" "Standard_DS2_v2")
  vm_created=false
  for candidate in "${VM_SIZE_CANDIDATES[@]}"; do
    echo "> Creating VM $VM_NAME (size $candidate, this can take a minute or two)..."
    if vm_out=$(az vm create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_NAME" \
      --image Ubuntu2404 \
      --vnet-name "$VNET_NAME" \
      --subnet "$SUBNET_NAME" \
      --admin-username "$ADMIN_USERNAME" \
      --authentication-type ssh \
      --size "$candidate" \
      --ssh-key-values "$SSH_KEY_PATH.pub" \
      --assign-identity \
      --role contributor \
      --public-ip-address "" \
      --nsg-rule NONE \
      --scope "/subscriptions/$AZURE_SUBSCRIPTION/resourceGroups/$RESOURCE_GROUP" 2>&1); then
      echo "✅ VM $VM_NAME created (size $candidate)."
      vm_created=true
      break
    fi

    # Only fall through to the next size on a capacity/availability error;
    # any other failure is fatal and is surfaced as-is.
    if printf '%s' "$vm_out" | grep -qi "SkuNotAvailable\|not available in location"; then
      echo "⚠️  Size $candidate is not available in $LOCATION; trying the next candidate..."
      continue
    fi

    printf '%s\n' "$vm_out" >&2
    exit 1
  done

  if [ "$vm_created" != "true" ]; then
    echo "❌ Could not create VM $VM_NAME: none of the candidate sizes are available in $LOCATION."
    echo "   List sizes offered in this region with:"
    echo "     az vm list-skus --location $LOCATION --resource-type virtualMachines -o table"
    echo "   Then re-run with an available size, e.g.: VM_SIZE=Standard_D2s_v4 $0"
    exit 1
  fi
else
  echo "✅ VM $VM_NAME already exists."
fi

# Get the private IP of the VM for DNAT rule configuration
VM_PRIVATE_IP=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --show-details \
  --query privateIps \
  --output tsv)

# =============================================================================
# DNAT RULE CONFIGURATION FOR SSH ACCESS
# =============================================================================

# Detect client IP if not set
# This allows the script to automatically detect the user's public IP
MY_CLIENT_IP="${MY_CLIENT_IP:-$(curl -s -4 ifconfig.me)}"
echo "✅ Using client IP: $MY_CLIENT_IP"
NORMAL_CLIENT_IP=${MY_CLIENT_IP//./_}

# Define DNAT rule collection and rule name based on client IP
# DNAT (Destination Network Address Translation) allows SSH access through the firewall
DNAT_COLLECTION_NAME="VMAccessCollection"
DNAT_RULE_NAME="SSHAccess_${NORMAL_CLIENT_IP}"

# Create DNAT rule if it doesn't exist
# This rule forwards SSH traffic from the client's IP to the VM's private IP
if ! az network firewall nat-rule show \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "$DNAT_COLLECTION_NAME" \
    --name "$DNAT_RULE_NAME" &>/dev/null; then

  # Check if this is the first DNAT rule in the collection
  COUNT=$(az network firewall nat-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "$DNAT_COLLECTION_NAME" \
    --query "length(@)" -o tsv 2>/dev/null || echo 0)

  if [ "$COUNT" -eq 0 ]; then
      echo "Creating DNAT rule $DNAT_RULE_NAME..."
      fw_run az network firewall nat-rule create \
        --firewall-name "$FIREWALL_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --collection-name "$DNAT_COLLECTION_NAME" \
        --name "$DNAT_RULE_NAME" \
        --protocols "TCP" \
        --priority 100 \
        --action "Dnat" \
        --source-addresses "$MY_CLIENT_IP" \
        --destination-addresses "$FW_PUBLIC_IP" \
        --destination-ports 22 \
        --translated-port 22 \
        --translated-address "$VM_PRIVATE_IP"
  else
      echo "Updating DNAT rule $DNAT_RULE_NAME..."
      fw_run az network firewall nat-rule create \
        --firewall-name "$FIREWALL_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --collection-name "$DNAT_COLLECTION_NAME" \
        --name "$DNAT_RULE_NAME" \
        --protocols "TCP" \
        --source-addresses "$MY_CLIENT_IP" \
        --destination-addresses "$FW_PUBLIC_IP" \
        --destination-ports 22 \
        --translated-port 22 \
        --translated-address "$VM_PRIVATE_IP"
  fi

  echo "✅ DNAT rule for SSH access created."
else
  echo "✅ DNAT rule for SSH access already exists."
fi

# =============================================================================
# CONNECTION SCRIPT GENERATION
# =============================================================================

echo "💻 You can now SSH into the VM via the Azure Firewall and use your Catalyst Private installation."
echo "---"
echo "Continue with next steps by returning to the README and following the instructions."
echo ""

# Add AKS credentials command to the setup script
echo "az aks get-credentials --name $AKS_NAME --overwrite-existing --resource-group $RESOURCE_GROUP" >> __setup.sh
echo " " >> __setup.sh

# Generate connect.sh script for easy VM access

# Copy the setup script to the VM
echo "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SSH_KEY_PATH} ./__setup.sh ${ADMIN_USERNAME}@${FW_PUBLIC_IP}:~/setup.sh" > connect.sh

# Connect to the VM via SSH through the firewall
echo "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SSH_KEY_PATH} ${ADMIN_USERNAME}@${FW_PUBLIC_IP}" >> connect.sh
