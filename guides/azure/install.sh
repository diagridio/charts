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
VM_NAME="${VM_NAME:-catalystv-vm}"
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

# Create an AKS cluster if it doesn't exist
if ! az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" &>/dev/null; then
  echo "> Creating AKS cluster $AKS_NAME..."
  az aks create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$AKS_NAME" \
    --load-balancer-sku standard \
    --network-plugin azure \
    --vnet-subnet-id "$(az network vnet subnet show \
      --resource-group "$RESOURCE_GROUP" \
      --vnet-name "$VNET_NAME" \
      --name "$SUBNET_NAME" --query id -o tsv)" \
    --dns-service-ip 10.42.0.10 \
    --service-cidr 10.42.0.0/24 \
    --enable-managed-identity \
    --enable-private-cluster \
    --node-count 3 \
    --ssh-key-value "$SSH_KEY_PATH.pub" \

  echo "✅ AKS cluster $AKS_NAME created."
else
  echo "✅ AKS cluster $AKS_NAME already exists."
fi

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

  echo "✅ VM $VM_NAME created."
else
  echo "✅ VM $VM_NAME already exists."
fi

# Output the public IP of the VM for SSH
VM_IP=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --show-details \
  --query publicIps \
  --output tsv)

echo ""
echo "💻 You can now SSH into the VM and use your Catalyst Private installation."
echo "---"
echo "To connect, run the following commands:"
echo "chmod +x ./connect.sh && ./connect.sh"
echo ""

# Backup the setup script
cp setup.sh setup.sh.bak

# Write to the setup script
echo "az aks get-credentials --name $AKS_NAME --overwrite-existing --resource-group $RESOURCE_GROUP" >> setup.sh
echo "" >> setup.sh

# Export variables
echo "echo \"export JOIN_TOKEN=${JOIN_TOKEN}\" > .env" >> setup.sh
echo "echo \"export API_KEY=${API_KEY}\" >> .env" >> setup.sh

# Copy the setup script to the VM
echo "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SSH_KEY_PATH} ./setup.sh ${ADMIN_USERNAME}@${VM_IP}:~" > connect.sh

# Connect to the VM via SSH
echo "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SSH_KEY_PATH} ${ADMIN_USERNAME}@${VM_IP}" >> connect.sh

# Restore the original setup script
mv setup.sh.bak setup.sh