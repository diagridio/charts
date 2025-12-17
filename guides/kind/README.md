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

# Create a new region and capture the join token
export JOIN_TOKEN=$(diagrid region create kind-region --ingress "https://*.127.0.0.1.nip.io:9082" | jq -r .joinToken)
```

> NOTE: we provide the ingress flag indicating how dapr runtime instances are going to be exposed. With this Diagrid Catalyst will be able to configure its gateway with the appropriate wildcard domain and the project URLs will be accurate with how the dapr runtime is exposed.

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
  --set image.repository=bitnamilegacy/postgresql \
  --create-namespace \
  --namespace postgres
```

## Step 4: Create self-signed certificate 🔐

# Install Cloudflare's CFSSL tool
```bash
# On macOS with Homebrew
brew install cfssl

# Or download binaries directly
go install github.com/cloudflare/cfssl/cmd/cfssl@latest
go install github.com/cloudflare/cfssl/cmd/cfssljson@latest
```

# Create a CA certificate configuration file

```bash
cat > ca-config.json << EOF
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "server": {
        "usages": ["signing", "key encipherment", "server auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF
```

# Create a certificate signing request (CSR) configuration file

Notice the use of the wildcard domain `*.127.0.0.1.nip.io` matching the ingress we
specified when creating the region.

```bash
cat > cert-csr.json << EOF
{
  "CN": "*.127.0.0.1.nip.io",
  "hosts": [
    "*.127.0.0.1.nip.io"
  ],
  "key": {
    "algo": "ecdsa",
    "size": 256
  },
  "names": [
    {
      "C": "US",
      "L": "Seattle",
      "O": "Awesome Company",
      "OU": "Engineering",
      "ST": "Washington"
    }
  ]
}
EOF
```

# Generate the CA and server certificates

```bash
cfssl gencert -initca cert-csr.json | cfssljson -bare ca
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=server cert-csr.json | cfssljson -bare server
```

# Trust the CA certificate

## On macOS

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.pem
```

## On Linux (Ubuntu)

```bash
# Copy certificate to trusted location
sudo cp ca.pem /usr/local/share/ca-certificates/kind-ca.crt

# Update CA certificates
sudo update-ca-certificates
```

## On Windows

```powershell
# Import the certificate
Import-Certificate -FilePath "ca.pem" -CertStoreLocation Cert:\LocalMachine\Root
```

## Step 5: Configure and Install Catalyst ⚡️

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
gateway:
  tls:
    enabled: true
EOF

# If you did not install PostgreSQL
cat > catalyst-values.yaml << EOF
agent:
  config:
    project:
      default_managed_state_store_type: postgresql-shared-disabled
gateway:
  tls:
    enabled: true
EOF

```

Install the Catalyst Helm chart:

```bash
# Install Catalyst using the Helm chart
helm install catalyst oci://public.ecr.aws/diagrid/catalyst \
     -n cra-agent \
     --create-namespace \
     -f catalyst-values.yaml \
     --set join_token="${JOIN_TOKEN}" \
     --set-file gateway.tls.cert=server.pem \
     --set-file gateway.tls.key=server-key.pem \
     --version 0.63.0-rc.1
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
kubectl port-forward -n cra-agent svc/gateway-envoy 9082:8443
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

```bash
# Start a listener for app1, wait until a log line like:
# ✅ Connected App ID "app1" to http://localhost:61016 ⚡️
diagrid listen -a app1

# Call app1 from app2
diagrid call invoke get app1.hello -a app2

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
