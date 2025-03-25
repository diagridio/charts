# Diagrid Helm Charts Repository

This repository contains official Helm charts published by Diagrid for deploying Diagrid products on Kubernetes.

> ⚠️ This repository is under active development. Documentation may be updated frequently.

## Available Charts

### Catalyst ⚡️

Diagrid Catalyst is a collection of API-based programming patterns for messaging, data, and workflow that is fully compliant with the Dapr open source project. It provides managed components and runtime that streamline cloud-native application development.

![Catalyst](./assets/img/catalyst.svg)

A Catalyst installation consists of the following components:
- **Agent**: Manages the configuration of Dapr projects.
- **Management**: Provides access to service providers such as secrets stores.
- **Gateway**: Provides routing to Dapr runtime instances.
- **Telemetry**: Collectors export telemetry from Dapr.

## Prerequisites

Before installing any charts, ensure you have the following tools:

- [Diagrid CLI](https://docs.diagrid.io/catalyst/references/cli-reference/intro)
- [Diagrid Account](https://catalyst.diagrid.io)
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [Helm](https://helm.sh/) (version 3.x or later)
- A Kubernetes cluster (1.20+ recommended)

## Installation
> NOTE: the default helm values are currently targeting the Diagrid dev environment.

### Step 1: Create a Region

First, create a Diagrid Region using the Diagrid CLI:

```bash
# Login to Diagrid
diagrid login

# Create a new region and capture the join token
export JOIN_TOKEN=$(diagrid region create myregion | jq -r .joinToken)
```

### Step 2: Install the Catalyst Helm Chart

#### Option A: Install from Diagrid's public OCI registry (recommended)

```bash
# Authenticate with the registry
aws ecr-public get-login-password \
     --region us-east-1 | helm registry login \
     --username AWS \
     --password-stdin public.ecr.aws

# Install the chart
helm install catalyst oci://public.ecr.aws/diagrid/catalyst \
     -n cra-agent \
     --create-namespace \
     --set "agent.config.host.join_token=${JOIN_TOKEN}" \
     --version 0.0.0-edge
```

#### Option B: Install from this repository

```bash
# Clone the repository (if you haven't already)
git clone https://github.com/diagridio/charts.git
cd charts

# Install the chart
helm install catalyst ./charts/catalyst/ \
     -n cra-agent \
     --create-namespace \
     --set "agent.config.host.join_token=${JOIN_TOKEN}"
```

The Catalyst installation will take a few minutes to onboard itself. During this time you may see pods restart but it will stabilize.

You can confirm the region exists in the CLI or web console.

```bash
diagrid region list
```

### Step 3: Create a Project in your Region
Your Region will now be available as a deployment option when creating Projects. For example:

```bash
diagrid project create myproject --region myregion
```

Now you're ready to start building you very first application. Head over to our [quickstarts](https://docs.diagrid.io/catalyst/quickstarts) to get started 🚀!

### Networking

#### Ingress 
Dapr runtime instances in a Catalyst region are made available to applications via their project's network address. For a private Catalyst installation, you must configure a wildcard DNS rule (`*.apps.myinternal.net`) so that your application's can resolve all project network addresses (e.g. `https://http-prj123.apps.myinternal.net`) to the IP address of the Catalyst gateway. You must also provide your wildcard domain when installing the Catalyst Helm Chart by setting the following Helm value:
```
agent.config.project.wildcard_domain=my-domain.com
```

### Secrets
The secrets provider allows Diagrid Catalyst to store and manage sensitive data specific to the resources hosted in a Region.

The default secrets provider is Kubernetes but you can also configure AWS Secrets Manager.

#### AWS Secrets Manager
Authentication to AWS Secret Manager can be configured using an access key and secret key, read more about AWS Access Keys [here](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html).

You can then provide the following Helm values:
```
global:
  secrets:
    provider: aws
    aws:
      region: us-west-1
      access_key: "mykey"
      secret_access_key: "key-secret"
```

### Workflows
To be able to support the Dapr Workflows API the Catalyst agent needs to be configured with a connection to a PostgreSQL instance. Catalyst uses this PostgreSQL instance to store and retrieve metadata about the workflow to provide features such as the Workflow Visualizer which is available at [catalyst.diagrid.io](https://catalyst.diagrid.io).

> NOTE: for testing purposes you can install a [PostgreSQL](https://github.com/bitnami/charts/tree/main/bitnami/postgresql) Helm Chart in the same Kubernetes cluster

You can configure the agent to use a PostgreSQL instance using the following Helm values:
```
agent:
  config:
    project:
      default_managed_state_store_type: postgresql-shared-external
      external_postgresql:
        enabled: true
        auth_type: connectionString
        connection_string_host: postgres.postgres.svc.cluster.local
        connection_string_port: 5432
        connection_string_username: root
        connection_string_password: postgres
```

## Docs

For more information about Diagrid Catalyst, including detailed usage instructions and examples, please visit:

- [Catalyst Documentation](https://docs.diagrid.io/catalyst)
- [Catalyst Support](https://docs.diagrid.io/catalyst/support)
- [Diagrid Website](https://www.diagrid.io/)
- [Diagrid Support](https://diagrid.io/support)

## Contributing

We welcome contributions to our Helm charts. Please feel free to submit issues or pull requests.

## License

Copyright © Diagrid, Inc.
