#!/bin/bash
# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/

# Install AWS CLI
dnf install -y unzip
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install

# Install Helm CLI
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x get_helm.sh
./get_helm.sh

# Install EC2 Instance Connect for IAM-based login
dnf install -y ec2-instance-connect

# Add the EKS kubeconfig
aws eks update-kubeconfig --name ${cluster_name} --region ${aws_region}

# Install Diagrid CLI
curl -o- https://downloads.diagrid.io/cli/install.sh | bash
sudo mv ./diagrid /usr/local/bin/diagrid
sudo chmod +x /usr/local/bin/diagrid