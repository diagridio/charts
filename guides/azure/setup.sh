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

# Install AWS CLI
echo "> Installing AWS CLI"
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
aws --version
echo "✅ Installed AWS CLI"

echo "✅ Installed Diagrid CLI"

# Install Azure CLI
echo "> Installing Azure CLI"

curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

echo "✅ Installed Azure CLI"

# Login to Azure
az login --identity

echo "✅ Azure login with MSI successful"

# ---
