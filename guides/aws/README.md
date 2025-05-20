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
export JOIN_TOKEN=$(diagrid region create my-aws-region --wildcard-domain placeholder.example.com | jq -r .joinToken)

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
cat terraform/terraform.tfvars | grep region | awk -F'"' '{print $2}'

# $> On the Bastion host SSH session

export EKS_CLUSTER_NAME="<value-from-output>"
export EKS_CLUSTER_REGION="<value-from-tfvars>"

aws eks update-kubeconfig --name $EKS_CLUSTER_NAME --region $EKS_CLUSTER_REGION

kubectl config current-context

# Set the default storage class to gp2
kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

## Step 5: Configure and Install Catalyst ⚡️

> [!IMPORTANT]
> It is possible to configure Catalyst to use the AWS secrets manager but this example uses the default Kubernetes secret manager.

Create a Helm values file for the Catalyst installation. This configuration sets up the Catalyst Gateway service as an AWS Network Load Balancer (NLB).

```bash
# $> On your local host machine

# view the RDS Postgresql connection details
make output postgresql_endpoint
make output postgresql_master_user_secret
# use this output to fetch the secret value from AWS Secret Manager with the secret arn.

# $> On the Bastion host SSH session

export RDS_POSTGRESQL_ENDPOINT="<value-from-output>" # remove port from endpoint
export RDS_POSTGRESQL_PASSWORD="<value-from-secrets-manager>" # fetch the password from AWS Secrets Manager

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
        connection_string_username: catalyst_dapr
        connection_string_password: $RDS_POSTGRESQL_PASSWORD
        connection_string_database: catalyst
gateway:
  envoy:
    service:
      type: LoadBalancer
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
        service.beta.kubernetes.io/aws-load-balancer-internal: "true"
EOF

# Authenticate Helm with the public AWS ECR registry
aws ecr-public get-login-password \
     --region us-east-1 | helm registry login \
     --username AWS \
     --password-stdin public.ecr.aws

# Install Catalyst using the Helm chart
helm install catalyst oci://public.ecr.aws/diagrid/catalyst \
     -n cra-agent \
     --create-namespace \
     -f catalyst-values.yaml \
     --set join_token="${JOIN_TOKEN}" \
     --version 0.0.0-edge # Or specify a desired version

```

## Step 6: Verify the Installation and Update Region ✅

Wait for all the Catalyst Kubernetes pods to be ready:

> [!NOTE]
> This may take several minutes ⏳

```bash
# $> On the Bastion host SSH session
kubectl -n cra-agent wait --for=condition=ready pod --all --timeout=5m

# Get the internal NLB hostname created for the gateway
export GATEWAY_IP=$(dig +short $(kubectl get svc gateway-envoy -n cra-agent -o jsonpath='{.status.loadBalancer.ingress[0].hostname}') | head -n1)

# Update the region with the a wildcard domain that will resolve to the gateway ip
export WILDCARD_DOMAIN="${GATEWAY_IP}.nip.io"
diagrid region update my-aws-region --wildcard-domain "$WILDCARD_DOMAIN"
```

## Step 7: Create a Project and Deploy App Identities 🚀

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

Send message between your App Identities from the original Bastion session:

```bash
# $> On your ORIGINAL terminal connected to the Bastion.

# Call app1 from app2 via the internal gateway using the wildcard domain
# The gateway runs on port 8080 by default in the chart
GATEWAY_TLS_INSECURE=true GATEWAY_PORT=8080 diagrid call invoke get app1.hello -a app2

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
