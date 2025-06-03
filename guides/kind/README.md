# Deploying Catalyst to a KinD Cluster

This guide shows how to deploy [Diagrid Catalyst](https://docs.diagrid.io/catalyst/) to a local [Kubernetes](https://kubernetes.io/) cluster using [KinD](https://kind.sigs.k8s.io/).

## KinD
[KinD](https://kind.sigs.k8s.io/) (Kubernetes in Docker) is a tool for running local Kubernetes clusters using [Docker](https://www.docker.com/) container nodes.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
- [Diagrid CLI](https://docs.diagrid.io/catalyst/references/cli-reference/intro)
- [Helm](https://helm.sh/)
- [jq](https://stedolan.github.io/jq/download/)
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (for OCI registry login)

## Step 1: Create a Kind Cluster 📦

Create a Kind cluster:

```bash
kind create cluster --name catalyst
```

## Step 2: Create a Catalyst Region 🏢

Use the [Diagrid CLI](https://docs.diagrid.io/catalyst/references/cli-reference/intro) to create a new Region:

```bash
# --api is only required when running against a none production environment.
diagrid login

# Set the wildcard domain that is going to be used to expose dapr runtime instances (e.g https://http-prj123.$WILDCARD_DOMAIN)
export WILDCARD_DOMAIN="127.0.0.1.nip.io"

# Create a new region and capture the join token
export JOIN_TOKEN=$(diagrid region create kind-region --wildcard-domain $WILDCARD_DOMAIN | jq -r .joinToken)
```

## Step 3: Install PostgreSQL (Optional) 💿

If you want to use the [Dapr Workflow API](https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-overview/), install [PostgreSQL](https://www.postgresql.org/):

```bash
# Add Bitnami chart repository
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Install PostgreSQL
helm install postgres bitnami/postgresql \
  --set auth.postgresPassword=postgres \
  --set auth.database=catalyst \
  --create-namespace \
  --namespace postgres
```

## Step 4: Configure and Install Catalyst ⚡️

Create a Helm values file for the Catalyst installation:

```bash
# If you installed PostresSQL
cat > catalyst-values.yaml << EOF
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
EOF

# If you did not install PostgreSQL
cat > catalyst-values.yaml << EOF
agent:
  config:
    project:
      default_managed_state_store_type: postgresql-shared-disabled
EOF

```

Install the Catalyst Helm chart:

```bash
# Authenticate with the public AWS registry
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
     --version 0.3.0
```

## Step 5: Verify the Installation ✅

Wait for all the Kubernetes pods to be ready:

> [!NOTE]
> This may take several minutes  ⏳

```bash
kubectl -n cra-agent wait --for=condition=ready pod --all --timeout=5m

# Verify the region exists and is connected
diagrid region list
```

## Step 6: Port Forward to Gateway

Port forward to the Gateway to expose Catalyst to your host machine.

```bash
kubectl port-forward -n cra-agent svc/gateway-envoy 9082:8080
```

## Step 7: Create a Project and Deploy App Identities 🚀

Create a Project in your Region

```bash
# Create the project
diagrid project create kind-project --region kind-region

# Use the project
diagrid project use kind-project
```

Create [App Identities](https://docs.diagrid.io/catalyst/concepts/appids)
```bash
diagrid appid create app1
diagrid appid create app2

# Wait until the appids are ready
diagrid appid list
```

Send messages between your App Identities

> [!WARNING]
> The Catalyst Gateway currently does not support TLS and expects it to be terminated externally. This will be fixed soon.

```bash
# Start a listener for app1, wait until a log line like:
# ✅ Connected App ID "app1" to http://localhost:61016 ⚡️
diagrid listen -a app1

# Call app1 from app2
GATEWAY_TLS_INSECURE=true GATEWAY_PORT=9082 diagrid call invoke get app1.hello -a app2

# You will now see the requests being received on your app 1 listener
# ...
# {
#   "method": "GET",
#   "url": "/hello"
# }
```

This proves that you are able to use [Dapr's service invocation API](https://docs.dapr.io/developing-applications/building-blocks/service-invocation/service-invocation-overview/) by calling your App Identity via the forwarded port.

In this scenario, we have used the Diagrid CLI to act as both the sending and receiving applications.

To view more details, open the Catalyst web console by running:

```bash
# Open the Catalyst console in your web browser
diagrid web
```

## Step 8: Write your applications 🎩

Now that you've demonstrated how to deploy a Project to your Catalyst Region along with 2 App Identities. You can head over to our [local development docs](https://docs.diagrid.io/catalyst/how-to-guides/develop-locally) to see how to start writing applications that can leverage App Identities to easily build distributed systems.
