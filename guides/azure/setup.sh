#!/bin/bash

# -------------------------------------------------------
# This script runs on the Azure VM to setup the environment
# -------------------------------------------------------

# Update package list
sudo apt update

# Install dependencies
sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release unzip

# Install kubectl
echo "> Installing kubectl"

curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256"
CHECKSUM=$(echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check)
if [ "$CHECKSUM" != "kubectl: OK" ]; then
  echo "Kubectl checksum verification failed!"
  exit 1
fi
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

echo "✅ Installed kubectl"

# Install Helm
echo "> Installing Helm"

curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
sudo ./get_helm.sh

echo "✅ Installed Helm"

# Install Diagrid CLI
echo "> Installing Diagrid CLI"
curl -o- https://downloads.diagrid.io/cli/install.sh | bash

sudo mv ./diagrid /usr/local/bin/diagrid
sudo chmod +x /usr/local/bin/diagrid

echo "✅ Installed Diagrid CLI"

# Install AWS CLI
echo "> Installing AWS CLI"
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
aws --version
echo "✅ Installed AWS CLI for retrieving Catalyst images from public ECR"

# Install Azure CLI
echo "> Installing Azure CLI"

sudo apt-get update
sudo apt-get install ca-certificates curl apt-transport-https lsb-release gnupg -y
curl -sL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null
AZ_REPO=$(lsb_release -cs)
echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" | sudo tee /etc/apt/sources.list.d/azure-cli.list
sudo apt-get update
sudo apt-get install azure-cli -y

echo "✅ Installed Azure CLI"

# Login to Azure
az login --identity

echo "✅ Azure login with MSI successful"

# ---
