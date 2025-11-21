# Deploying Catalyst to AWS

This guide demonstrates how to deploy Catalyst Private in a private AWS Virtual Private Cloud (VPC). This setup is for demonstration purposes only and this should not be used in production.

> [!NOTE]
> This guide assumes a Linux or MacOS environment for running the scripts. Adaptations might be needed for Windows.

## Prerequisites

- [Diagrid CLI](https://docs.diagrid.io/catalyst/references/cli-reference/intro)
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (configured with credentials for your AWS account)
- [Helm](https://helm.sh/)
- [jq](https://stedolan.github.io/jq/download/)
- An AWS account with permissions to create VPC, EKS, EC2, IAM, and related resources.

## Step 1: Create a Catalyst Region 🏢

Use the [Diagrid CLI](https://docs.diagrid.io/catalyst/references/cli-reference/intro) to create a new Region. The wildcard domain will be configured later based on the Load Balancer service created by the Helm chart.

```bash
diagrid login

# Create a new region (we'll update the wildcard domain later)
export JOIN_TOKEN=$(diagrid region create my-aws-region --ingress placeholder.example.com | jq -r .joinToken)

# Create an api key to use the Diagrid CLI in AWS later
export API_KEY=$(diagrid apikey create --name aws-key --role cra.diagrid:editor --duration 8640 | jq -r .token)
```

## Step 2: Deploy your AWS Resources 📦

Use the provided Terraform to deploy the required infrastructure to your AWS account.

```bash
# Login to AWS cli and ensure you are on the correct profile
aws sts get-caller-identity

# Initialize terraform
make init

# Show the terraform plan
make plan

# Apply the terraform plan
make apply
```

This will deploy an EKS cluster to a VPC along with a Bastion host that you can use to securely access your EKS cluster to perform admin operations.

## Step 3: Connect to the Bastion Host 🖥️

You can now use SSH to connect via ec2-instance-connect to the Bastion host.

```bash
EC2_CONNECT_CMD=$(make output bastion_ec2_instance_connect_command)

# Execute the ec2 connect command
eval $EC2_CONNECT_CMD
```

You are now connected to the Bastion host, which resides within the private VPC and can communicate with the EKS cluster.

## Step 4: Setup Kubernetes ⚙️

The Bastion host will have installed `kubectl` and will be configured to access your EKS cluster.

```bash
# $> On your local host machine

# view the EKS cluster name
make output eks_cluster_name

# view the EKS cluster region
make output eks_cluster_region

# $> On the Bastion host SSH session

export EKS_CLUSTER_NAME="<value-from-eks_cluster_name-output>"
export EKS_CLUSTER_REGION="<value-from-eks_cluster_region-output>"

aws eks update-kubeconfig --name $EKS_CLUSTER_NAME --region $EKS_CLUSTER_REGION

kubectl config current-context

# Set the default storage class to gp2
kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### Optional: Install and configure [krew kubectl plugin manager](https://krew.sigs.k8s.io/docs/user-guide/setup/install/)

# $> On the Bastion host SSH session

```bash
sudo yum install git --assumeyes
(
  set -x; cd "$(mktemp -d)" &&
  OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
  ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
  KREW="krew-${OS}_${ARCH}" &&
  curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
  tar zxvf "${KREW}.tar.gz" &&
  ./"${KREW}" install krew
)

cat >> ~/.bashrc << EOF
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
EOF
```

# Restart your shell so that PATH changes take effect

```bash
# $> On the Bastion host SSH session, install kubens and kubectx, add helpers to .alias

kubectl krew install ctx
kubectl krew install ns

cat >> ~/.bashrc << EOF
source ~/.alias
EOF

cat > ~/.alias << EOF
alias k='kubectl'
alias kp='kubectl get pods'
alias kpa='kubectl get pods --all-namespaces'
alias kf='kubectl logs -f'
alias kx='k ctx'
alias kns='k ns'
EOF
```

## Step 6: Install AWS's Load Balancer Controller

```bash
# $> On your local host machine

# view the EKS cluster name 
make output eks_cluster_name

# view the AWS Load Balancer Controller role arn
make output aws_load_balancer_controller_role_arn

# $> On the Bastion host SSH session

# Add the EKS chart repository
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

helm upgrade -install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system \
    --set clusterName=<value-from-eks_cluster_name> \
    --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<value-from-aws_load_balancer_controller_role_arn-output>
```

## Step 7: Install Certificate Manager

```bash
# $> On your local host machine

# view the Certificate Manager role arn
make output cert_manager_role_arn

# $> On the Bastion host SSH session

helm repo add jetstack https://charts.jetstack.io --force-update

helm upgrade -install \
  cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version 0.38.0 \
  --set crds.enabled=true \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<value-from-cert_manager_role_arn-output>
```

### Install Let's Encrypt Cluster Issuer

```bash
# $> On your local host machine

# view the Certificate Manager role arn
make output cert_manager_role_arn

# $> On the Bastion host SSH session

cat >> ~/lets-encrypt-cluster-issuer.yaml << EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
  namespace: cert-manager
spec:
  acme:
    email: support@diagrid.io
    privateKeySecretRef:
      name: letsencrypt
    server: https://acme-v02.api.letsencrypt.org/directory
    solvers:
    - dns01:
        route53:
          region: us-west-2
          role: <value-from-cert_manager_role_arn-output>
          auth:
            kubernetes:
              serviceAccountRef:
                name: cert-manager
EOF
```

## Step 8: Install monitoring tools

### Install Metrics Server

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/

helm upgrade --install metrics-server metrics-server/metrics-server
```

### Install Prometheus Node Exporter

```bash
cat > ~/prometheus-node-exporter-config.yaml << EOF
podAnnotations:
  prometheus.io/path: /metrics
  prometheus.io/port: "9100"
  prometheus.io/scrape: "true"
rbac:
  pspEnabled: false
resources:
  limits:
    memory: 50Mi
  requests:
    cpu: 10m
    memory: 25Mi
EOF

helm install prometheus-node-exporter oci://ghcr.io/prometheus-community/charts/prometheus-node-exporter --values prometheus-node-exporter-config.yaml
```

### Install Kube state metrics

```bash
cat > ~/kube-state-metrics-config.yaml << EOF
podAnnotations:
  prometheus.io/port: "8080"
  prometheus.io/scrape: "true"
EOF

helm install kube-state-metrics oci://ghcr.io/prometheus-community/charts/kube-state-metrics --values kube-state-metrics-config.yaml
```

## Step 9: Configure and Install Catalyst ⚡️

> [!IMPORTANT]
> It is possible to configure Catalyst to use the AWS secrets manager but this example uses the default Kubernetes secret manager.

Create a Helm values file for the Catalyst installation. This configuration sets up the Catalyst Gateway service as an AWS Network Load Balancer (NLB).

```bash
# $> On your local host machine

# view the RDS Postgresql connection details
make output postgresql_endpoint
make output postgresql_master_user_secret_arn
make output eks_cluster_region

# use this output to fetch the secret value from AWS Secret Manager with the secret arn.
aws --region $(make output eks_cluster_region) secretsmanager get-secret-value --secret-id $(make output postgresql_master_user_secret_arn) --query SecretString --output text | jq '.password'

# $> On the Bastion host SSH session

export RDS_POSTGRESQL_ENDPOINT="<value-from-postgresql_endpoint-output>"
export RDS_POSTGRESQL_PASSWORD="<value-from-aws-cli>" 

# Create base catalyst-values.yaml
cat > catalyst-values.yaml << EOF
agent:
  config:
    project:
      default_managed_state_store_type: postgresql-shared-external
      external_postgresql:
        enabled: true
        auth_type: connectionString
        namespace: postgresql
        connection_string_host: $RDS_POSTGRESQL_ENDPOINT
        connection_string_port: 5432
        connection_string_username: postgres
        connection_string_password: "$RDS_POSTGRESQL_PASSWORD"
        connection_string_database: catalyst
gateway:
  tls:
    enabled: true
    secretName: "cert-wildcard"
  envoy:
    service:
      type: LoadBalancer
      httpsPort: 443
      httpsTargetPort: 8443
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
        service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol: "tcp"
        service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
        service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "instance"
EOF

# Install Catalyst using the Helm chart
helm install catalyst oci://public.ecr.aws/diagrid/catalyst \
     -n cra-agent \
     --create-namespace \
     -f catalyst-values.yaml \
     --set join_token="${JOIN_TOKEN}" \
     --version 0.38.0
```

## Step 11: Setup ingress and wildcard TLS certificate

This final step will create a Route53 hosted zone and a wildcard TLS certificate for the domain that you own.
This will allow you to access your Catalyst Gateway securely.

```bash
# $> On your local host machine
REGION_INGRESS_ENDPOINT="<somename>.<domain that you own>" make apply

make output region_ingress_endpoint

# Update the region with the a wildcard domain that you've just created
diagrid region update my-aws-region --ingress "<value-from-region_ingress_endpoint-output>"
```

Now you'll need to make further configurations to your top level domain in order to delegate the subdomain to Route53.
This is done by creating NS records in your domain registrar's DNS settings that point to the Route53 hosted zone's nameservers.
At the end you should be getting back a reply to with the NLB IP address when you run:

```bash
dig whatever.<somename>.<domain that you own>
```

### Create a Let's Encrypt TLS certificate

```bash
# $> On your local host machine
make output region_wildcard_domain

# $> On the Bastion host SSH session

cat >> ~/wildcard-certificate.yaml << EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cert-wildcard
  namespace: cra-agent
spec:
  dnsNames:
  - "<value-from-region_wildcard_domain-output>"
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: letsencrypt
  secretName: cert-wildcard
  usages:
  - digital signature
  - key encipherment
EOF

k apply -f ~/wildcard-certificate.yaml
```

## Step 11: Verify the Installation ✅

Wait for all the Catalyst Kubernetes pods to be ready:

> [!NOTE]
> This may take several minutes ⏳

```bash
# $> On the Bastion host SSH session
kubectl -n cra-agent wait --for=condition=ready pod --all --timeout=5m
```

## Step 12: Create a Project and Deploy App Identities 🚀

Create a new Project in your Region:
```bash
# $> On your local host machine

# Create the project
diagrid project create aws-project --region my-aws-region --use

# Create some appids to test
diagrid appid create app1
diagrid appid create app2

# Wait until the appids are ready
diagrid appid list
```

Now that we have a Project and App Identities, we need to test them. We are assuming that your local machine does not have direct access to the gateway IP and thus we need to test this from within the VPC.

Open a **new terminal window** on your local machine and connect to the Bastion host again to start a listener:

```bash
# $> On your NEW terminal on your local host machine

EC2_CONNECT_CMD=$(make output bastion_ec2_instance_connect_command)

# Execute the ec2 connect command
eval $EC2_CONNECT_CMD

# $> On the NEW Bastion host SSH session
diagrid login --api-key="$API_KEY" # API_KEY taken from Step 1.
diagrid project use aws-project

# The Diagrid CLI can create a listener for your App Identity and will print any requests that are sent to it.
# Start the listener for app1, wait until a log line like:
# ✅ Connected App ID "app1" to http://localhost:<port> ⚡️
diagrid listen -a app1
```

Send messages between your App Identities from the original Bastion session:

```bash
# $> On your ORIGINAL terminal connected to the Bastion.

# Call app1 from app2 via the internal gateway using the wildcard domain
diagrid call invoke get app1.hello -a app2

# You should now see the request received ('method': 'GET', 'url': '/hello')
# in the output of the 'diagrid listen -a app1' command in the other terminal.
```

This proves that you can use [Dapr's service invocation API](https://docs.dapr.io/developing-applications/building-blocks/service-invocation/service-invocation-overview/) by calling your App Identity via the internal NLB using the wildcard domain assigned to the Catalyst Region.

To view your project details, open the Catalyst web console:

```bash
# $> On your local host machine
diagrid web
```

## Step 8: Write your applications 🎩

Now that you've deployed a Project to your Catalyst Region on AWS along with 2 App Identities, you can head over to our [local development docs](https://docs.diagrid.io/catalyst/how-to-guides/develop-locally) to see how to start writing applications that leverage App Identities. Remember that applications running within the VPC can directly access the internal gateway at `http://<GATEWAY_HOSTNAME>:8080`.

This guide is only for demonstration purposes. You are expected to setup your region using a domain that you own that can direct traffic from your applications to your Catalyst Gateway. You can configure the Catalyst Gateway with TLS by setting the Catalyst Helm values `gateway.tls.enabled` to `true` and creating a Kubernetes TLS secret for your server key and certificate called `gateway-tls-certs` in the `cra-agent` namespace. Your applications must be able to connect to your Catalyst Gateway and must trust the root CA for the TLS certificates you use. You can then set the appropriate env vars show below and connect to your Catalyst installation using the Dapr SDKs.
- `DAPR_GRPC_ENDPOINT=<your-project-grpc-url>`
- `DAPR_HTTP_ENDPOINT=<your-project-http-url>`
- `DAPR_API_TOKEN=<your-appid-api-token>`
