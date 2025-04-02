#!/bin/bash

set -euo pipefail

if ! command -v az &> /dev/null
then
    echo "Azure CLI could not be found"
    echo "please install Azure CLI by running: brew install azure-cli"
    exit
fi
if ! command -v kubectl &> /dev/null
then
    echo "kubectl could not be found"
    echo "please install kubectl by running: brew install kubectl"
    exit
fi
if [ -z "$JOIN_TOKEN" ]; then
  echo "JOIN_TOKEN is not set. Please set it before running this script."
  exit 1
fi
if [ -z "$API_KEY" ]; then
  echo "API_KEY is not set. Please set it before running this script."
  exit 1
fi

# Default values that can be overridden via environment variables
RESOURCE_GROUP="${RESOURCE_GROUP:-catalyst-private}"
LOCATION="${LOCATION:-eastus}"
VNET_NAME="${VNET_NAME:-catalyst-vnet}"
SUBNET_NAME="${SUBNET_NAME:-catalyst-subnet}"
LOADBALANCER_IPV4="${LOADBALANCER_IPV4:-10.42.2.180}"
ADDRESS_PREFIX="${ADDRESS_PREFIX:-10.42.0.0/16}"
SUBNET_PREFIX="${SUBNET_PREFIX:-10.42.1.0/24}"
AKS_NAME="${AKS_NAME:-catalyst-cluster}"
VM_NAME="${VM_NAME:-catalyst-vm}"
VM_SIZE="${VM_SIZE:-Standard_B2s}"
ADMIN_USERNAME="${ADMIN_USERNAME:-azureuser}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"

if [[ ! -f "$SSH_KEY_PATH" || ! -f "$SSH_KEY_PATH.pub" ]]; then
  echo "SSH key not found at $SSH_KEY_PATH. Please generate an SSH key pair and place the public key at this location."
  exit 1
fi

chmod 400 "$SSH_KEY_PATH"
echo "🔑 Using SSH key from $SSH_KEY_PATH"

echo "📦 Ensuring Azure resources..."

# Create a Resource Group if it doesn't exist
if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
  echo "> Creating resource group $RESOURCE_GROUP..."
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

  echo "✅ Resource group $RESOURCE_GROUP created."
else
  echo "✅ Resource group $RESOURCE_GROUP already exists."
fi

# Create a VNet and Subnet if they don't exist
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

FIREWALL_NAME="catalyst-firewall"
FIREWALL_SUBNET_NAME="AzureFirewallSubnet"
FIREWALL_SUBNET_PREFIX="10.42.2.0/24"

# Create the Firewall subnet if it doesn't exist
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

# Create Azure Firewall if it doesn't exist
if ! az network firewall show --resource-group "$RESOURCE_GROUP" --name "$FIREWALL_NAME" &>/dev/null; then

  echo "> Creating Azure Firewall $FIREWALL_NAME..."
  az network firewall create \
    --name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION"

  echo "✅ Azure Firewall $FIREWALL_NAME created."
else
  echo "✅ Azure Firewall $FIREWALL_NAME already exists."
fi

# Create a public IP for the Firewall if it doesn't exist
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

# Create a Firewall IP configuration if it doesn't exist
if ! az network firewall ip-config show --firewall-name "$FIREWALL_NAME" --resource-group "$RESOURCE_GROUP" --name catalystFirewallConfig &>/dev/null; then
  echo "> Configuring Firewall IP configuration..."
  az network firewall ip-config create \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --name catalystFirewallConfig \
    --vnet-name "$VNET_NAME" \
    --subnet "$FIREWALL_SUBNET_NAME" \
    --public-ip-address "$FIREWALL_NAME"

  echo "✅ Firewall IP configuration created."
else
  echo "✅ Firewall IP configuration already exists."
fi

echo "> Updating Firewall policy..."
az network firewall update \
--name "$FIREWALL_NAME" \
--resource-group "$RESOURCE_GROUP"

FW_PUBLIC_IP=$(az network public-ip show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$FIREWALL_NAME" \
  --query ipAddress -o tsv)

# Get Firewall's private IP for routing
FW_PRIVATE_IP=$(az network firewall show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$FIREWALL_NAME" \
  --query "ipConfigurations[0].privateIPAddress" -o tsv)

# Create a route table to route AKS outbound traffic via the firewall
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

# Create time network rule collection if it doesn't exist
if ! az network firewall network-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowTimeCollectionGroup" 2>/dev/null \
    | grep -q "AllowNetworkAzure"; then

  echo "> Configuring network rules (time) for the firewall..."
  az network firewall network-rule create \
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
if ! az network firewall network-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowDNSCollectionGroup" 2>/dev/null \
    | grep -q "AllowNetworkAzure"; then

  echo "> Configuring network rules (dns) for the firewall..."
  az network firewall network-rule create \
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
if ! az network firewall network-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowServiceTagsCollectionGroup" 2>/dev/null \
    | grep -q "AllowNetworkAzure"; then

  echo "> Configuring network rules (servicetags) for the firewall..."
  az network firewall network-rule create \
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
if ! az network firewall network-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowApiTcpCollectionGroup" 2>/dev/null \
    | grep -q "AllowNetworkAzure"; then

  echo "> Configuring network rules (apitcp) for the firewall..."
  az network firewall network-rule create \
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

# Create network rule (ApiTCP) collection if it doesn't exist
if ! az network firewall network-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowApiUdpCollectionGroup" 2>/dev/null \
    | grep -q "AllowNetworkAzure"; then

  echo "> Configuring network rules (apiudp) for the firewall..."
  az network firewall network-rule create \
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

# Create application rule collection if it doesn't exist
if ! az network firewall application-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowApplicationRuleCollectionGroup" 2>/dev/null \
    | grep -q "AllowRuleApplication"; then

  echo "> Configuring application rules for the firewall..."
  TARGET_FQDNS=(
    # diagrid
    "*.diagrid.io"
    # kubenetes
    "*.dl.k8s.io"
    "dl.k8s.io"
    # github
    "github.com"
    "api.github.com"
    "*.githubusercontent.com"
    "ghcr.io"
    # azure (https://learn.microsoft.com/en-us/azure/aks/outbound-rules-control-egress)
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
    # aws
    "*.amazonaws.com"
    "*.s3.amazonaws.com"
    "public.ecr.aws"
    # gcp
    "gcr.io"
    "storage.googleapis.com"
    "us-central1-docker.pkg.dev"
    # helm
    "get.helm.sh"
    "charts.bitnami.com"
    "*.cloudfront.net"
    "repo.broadcom.com"
    # docker
    "*.docker.io"
    "*.docker.com"
    "registry-1.docker.io"
    "production.cloudflare.docker.com"
    # ngrok
    "*.ngrok.io"
    "*.ngrok.com"
    "*.ngrok-agent.com"
    "*.equinox.io"
    # ubuntu
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

  az network firewall application-rule create \
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
if ! az network firewall application-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowAKSCollectionGroup" 2>/dev/null \
    | grep -q "AllowRuleApplication"; then

  echo "> Configuring application rules (aks) for the firewall..."

  az network firewall application-rule create \
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

# Create AKS cluster if it doesn't exist
if ! az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" &>/dev/null; then
  echo "> Creating AKS cluster $AKS_NAME..."
  
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
    --node-count 3 \
    --ssh-key-value "$SSH_KEY_PATH.pub" \
    --outbound-type userDefinedRouting

  echo "✅ AKS cluster $AKS_NAME created."
else
  echo "✅ AKS cluster $AKS_NAME already exists."
fi

KUBE_API_SERVER_IP=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --query privateFqdn -o tsv)

# Add Kubernetes API server IP to the firewall rules if needed
if ! az network firewall application-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "AllowKubernetesApiRuleCollectionGroup" 2>/dev/null | grep -q "$KUBE_API_SERVER_IP"; then

  echo "> Adding Kubernetes API server IP to firewall rules..."
  az network firewall application-rule create \
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

AZURE_SUBSCRIPTION=$(az account show --query id -o tsv)

# Create a VM if it doesn't exist
if ! az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" >/dev/null 2>&1; then
  echo "> Creating VM $VM_NAME..."
  az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --image Ubuntu2404 \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_NAME" \
    --admin-username "$ADMIN_USERNAME" \
    --authentication-type ssh \
    --size "$VM_SIZE" \
    --ssh-key-values "$SSH_KEY_PATH.pub" \
    --assign-identity \
    --role contributor \
    --public-ip-address "" \
    --nsg-rule NONE \
    --scope "/subscriptions/$AZURE_SUBSCRIPTION/resourceGroups/$RESOURCE_GROUP"

  echo "✅ VM $VM_NAME created."
else
  echo "✅ VM $VM_NAME already exists."
fi

# Get the private IP of the VM
VM_PRIVATE_IP=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --show-details \
  --query privateIps \
  --output tsv)

# Detect client IP if not set
MY_CLIENT_IP="${MY_CLIENT_IP:-$(curl -s ifconfig.me)}"
echo "✅ Using client IP: $MY_CLIENT_IP"
NORMAL_CLIENT_IP=${MY_CLIENT_IP//./_}

# Define DNAT rule collection and rule name based on client IP
DNAT_COLLECTION_NAME="VMAccessCollection"
DNAT_RULE_NAME="SSHAccess_${NORMAL_CLIENT_IP}"

if ! az network firewall nat-rule show \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "$DNAT_COLLECTION_NAME" \
    --name "$DNAT_RULE_NAME" &>/dev/null; then

  COUNT=$(az network firewall nat-rule list \
    --firewall-name "$FIREWALL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --collection-name "$DNAT_COLLECTION_NAME" \
    --query "length(@)" -o tsv 2>/dev/null || echo 0)

  if [ "$COUNT" -eq 0 ]; then
      echo "Creating DNAT rule $DNAT_RULE_NAME..."
      az network firewall nat-rule create \
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
      az network firewall nat-rule create \
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

echo ""
echo "💻 You can now SSH into the VM via the Azure Firewall and use your Catalyst Private installation."
echo "---"
echo "To connect, run the following commands:"
echo "chmod +x ./connect.sh && ./connect.sh"
echo ""

# Create copy of setup.sh
cp setup.sh __setup.sh

# Write to the setup script
echo "az aks get-credentials --name $AKS_NAME --overwrite-existing --resource-group $RESOURCE_GROUP" >> __setup.sh
echo "" >> __setup.sh

# Export variables
echo "echo \"export JOIN_TOKEN=${JOIN_TOKEN}\" > .env" >> __setup.sh
echo "echo \"export API_KEY=${API_KEY}\" >> .env" >> __setup.sh

# Copy the setup script to the VM
echo "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SSH_KEY_PATH} ./__setup.sh ${ADMIN_USERNAME}@${FW_PUBLIC_IP}:~/setup.sh" > connect.sh

# Connect to the VM via SSH
echo "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SSH_KEY_PATH} ${ADMIN_USERNAME}@${FW_PUBLIC_IP}" >> connect.sh
