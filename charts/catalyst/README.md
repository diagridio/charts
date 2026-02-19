# Catalyst Helm Chart

## Overview

Catalyst is an enterprise platform for workflow orchestration, service discovery and pub/sub, powered by Dapr. Build apps and AI agents that are compliant, secure and failure-proof. Find out more at [diagrid.io/catalyst](https://www.diagrid.io/catalyst).

**Catalyst Private** enables you to self-host a Catalyst region within your own environment while using it as a service via Diagrid Cloud. This architecture separates the control plane (hosted by Diagrid Cloud) from the data plane (hosted in your Kubernetes cluster). The control plane manages configuration, while the data plane handles application connectivity and data.

You interact with your Catalyst Private installation via the [Diagrid Cloud web console](https://catalyst.diagrid.io) and CLI. The console fetches app data directly from your installation, so your machine must be able to reach your Catalyst Private ingress.

![Catalyst](../../assets/img/catalyst.svg)

## Dapr API Compatibility

Diagrid Catalyst supports the following Dapr APIs:
- [Workflows](https://docs.dapr.io/reference/api/workflow_api/)
- [Conversation](https://docs.dapr.io/reference/api/conversation_api/)
- [Service Invocation](https://docs.dapr.io/reference/api/service_invocation_api/)
- [State Management](https://docs.dapr.io/reference/api/state_api/)
- [Pub/Sub](https://docs.dapr.io/reference/api/pubsub_api/)
- [Bindings](https://docs.dapr.io/reference/api/bindings_api/)
- [Actors](https://docs.dapr.io/reference/api/actors_api/)
- [Secrets](https://docs.dapr.io/reference/api/secrets_api/)
- [Jobs](https://docs.dapr.io/reference/api/jobs_api/)
- [Distributed Lock](https://docs.dapr.io/reference/api/distributed_lock_api/)

## Components

- **Agent**: Manages Dapr project configuration.
- **Management**: Accesses service providers (e.g., secrets stores).
- **Gateway**: Routes to Dapr runtime instances.
- **Telemetry**: Exports telemetry from Dapr.
- **Piko**: Tunnels to applications on private networks.

## Guides
For step-by-step guides on deploying Catalyst to various Kubernetes environments, please refer to the following:

- [Deploying Catalyst to a KinD Cluster](../../guides/kind/README.md)
- [Deploying Catalyst to an Azure Kubernetes Service Cluster](../../guides/azure/README.md)
- [Deploying Catalyst to an AWS Elastic Kubernetes Service Cluster](../../guides/aws/README.md)

## Prerequisites

- Kubernetes 1.20+
- [Helm](https://helm.sh/) v3.12.0+
- [Diagrid CLI](https://docs.diagrid.io/catalyst/references/cli-reference/intro)

## Chart Dependencies

This chart includes the following dependencies:

- **OpenTelemetry Collector** - Optional telemetry collection and export

For local development or when working from source, see the [Development](#development) section below.

## Install

### Obtain a Join Token

Before installing Catalyst, you need to obtain a join token from [Diagrid Cloud](https://catalyst.diagrid.io):

1. Sign up or log in to [Diagrid Catalyst](https://catalyst.diagrid.io)
2. Create a new `region` via the [Diagrid CLI](https://docs.diagrid.io/catalyst/references/cli-reference/intro):

```bash
diagrid login

export JOIN_TOKEN=$(diagrid region create <region-name> --ingress "https://<ingress-domain>" | jq -r .joinToken)
```

> **NOTE:** The join token can be regenerated before successfully completing the installation, but not after.

### Installing the Chart

```bash
# Install Catalyst using the Helm chart
helm install catalyst oci://public.ecr.aws/diagrid/catalyst \
     -n cra-agent \
     --create-namespace \
     -f catalyst-values.yaml \
     --set join_token="${JOIN_TOKEN}"
```

## Uninstall
To uninstall Catalyst and clean up all associated resources, run the following command:

```bash
helm uninstall catalyst -n cra-agent
```

> **WARNING:**  The `region` resource is intended for a single installation, once you uninstall Catalyst, the region is no longer valid. If you want to uninstall Catalyst but allow re-installation, remove the clean up hook by setting the values:

```bash
cleanup:
  enabled: false
```

## Configuration

### Cluster Requirements

Catalyst should be installed in a dedicated Kubernetes cluster. It manages global resources and dynamically provisions workloads, which may conflict with other applications in a shared cluster.

### Permissions

Catalyst components require broad permissions to dynamically manage resources. We are working to reduce this scope in future releases.

### Images

The chart deploys multiple images. Below is a reference for users who need to mirror images to private registries.

#### Installation Images

Most images are hosted in the Diagrid public repository:
`REPO=us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public`

By default, a consolidated image is used:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Catalyst** | `$REPO/catalyst-all:<tag>` | Catalyst services |

Alternatively, separate images can be used:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Catalyst Agent** | `$REPO/cra-agent:<tag>` | Catalyst agent service |
| **Catalyst Management** | `$REPO/catalyst-management:<tag>` | Catalyst management service |
| **Gateway Control Plane** | `$REPO/catalyst-gateway:<tag>` | Gateway control plane service |
| **Gateway Identity Injector** | `$REPO/identity-injector:<tag>` | Identity injection service |

Dependencies:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Envoy Proxy** | `envoyproxy/envoy:<tag>` | Envoy proxy for gateway |
| **Piko** | `dotjson/piko:<tag>` | Piko reverse tunneling service |

#### Runtime Images

The Agent provisions these at runtime:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Dapr Server** | `$REPO/sidecar:<tag>` | Catalyst dapr server |
| **OpenTelemetry Collector** | `$REPO/diagrid-otel-collector:<tag>` | OTel collector for telemetry |
| **Dapr Control Plane (Catalyst)** | `$REPO/dapr:<tag>` | Catalyst Dapr control plane services |
| **Dapr Control Plane (OSS)** | `daprio/dapr:<tag>` | Dapr control plane services |

#### Optional Images

Used when OpenTelemetry addons are enabled:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **OpenTelemetry Collector (OSS)** | `ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-k8s:<tag>` | Collector for traces, metrics, and logs |

### Private Image Registry

For air-gapped environments, use the provided script to mirror images to your private registry.

```bash
./scripts/catalyst/mirror-images.sh my-registry.example.com \
  --catalyst-version 0.469.0 \
  --dapr-version 1.16.2 \
  --internal-dapr-version 1.16.2-catalyst.1 \
  --envoy-version distroless-v1.33.0 \
  --piko-version v0.8.2 \
  --otel-version 0.112.0
```

Configure your values file:

```yaml
global:
  image:
    registry: my-registry.example.com
```

If using OpenTelemetry addons:

```yaml
opentelemetry-deployment:
  enabled: true
  image:
    repository: my-registry.example.com/opentelemetry-collector-k8s
    tag: "0.112.0"

opentelemetry-daemonset:
  enabled: true
  image:
    repository: my-registry.example.com/opentelemetry-collector-k8s
    tag: "0.112.0"
```

### Private Helm Registry

To mirror the chart to a private registry:

```bash
helm pull oci://public.ecr.aws/diagrid/catalyst --version <version>
helm push catalyst-<version>.tgz oci://my-registry.example.com/diagrid/catalyst
```

Configure authentication in `values.yaml`:

```yaml
global:
  charts:
    registry: "oci://my-registry.example.com/diagrid/catalyst"
    username: "my-username"
    password: "my-password"
    # Or use existingSecret, clientCert, clientKey, customCA
```

### Dapr PKI

By default, Dapr Sentry generates a self-signed root CA. For production, integrate with your own PKI by providing an issuer CA and trust anchors:

```yaml
agent:
  config:
    internal_dapr:
      ca:
        issuer_secret_name: "issuer-secret"
        trust_anchors_config_map_name: "trust-anchors"
        namespace: "cra-agent"
```

### Pod Security and Seccomp Profiles

Catalyst components expose `podSecurityContext` and `securityContext` values so you can enforce enterprise pod security standards, including custom seccomp profiles.

Example using a node-local seccomp profile:

```yaml
agent:
  podSecurityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/catalyst-agent.json
```

### Gateway TLS

To terminate TLS at the Catalyst Gateway, provide a certificate and key:

```yaml
gateway:
  tls:
    enabled: true
    existingSecret: "my-tls-secret"
    # Or provide cert/key inline
```

### Workflows

Catalyst uses an external PostgreSQL database to store workflow state and provide rich visualizations. To enable this feature, configure the connection details as follows:

```yaml
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
```

If you wish to disable this feature, you must set:

```yaml
agent:
  config:
    project:
      default_managed_state_store_type: postgresql-shared-disabled
```

### OpenTelemetry Collector (Optional)

Catalyst includes optional OpenTelemetry Collector addons for collecting and exporting telemetry. See the [official documentation](https://opentelemetry.io/docs/collector/configuration/) for configuration details.

### Tracing Support

Catalyst supports sending tracing data to various backends through [Dapr configuration](https://docs.dapr.io/operations/observability/tracing/setup-tracing/).
To configure tracing for your application you'll first need to create a dapr configuration with the apropriate entries,
in the example below we are configuring it to use Jaeger as the backend running within the same kubernetes cluster:

```bash
cat <<EOF > tracing-config.yaml
apiVersion: dapr.io/v1alpha1
kind: Configuration
metadata:
  name: tracing-config
spec:
  tracing:
    samplingRate: "1"
    stdout: true
    otel:
      endpointAddress: "jaeger.jaeger.svc.cluster.local:4317"
      isSecure: false
      protocol: grpc 
EOF
```

This configuration can now be applied using the Diagrid CLI:

```bash
diagrid apply -f tracing-config.yaml
```

Finally, to enable tracing for your application, it must be configured to use it:

```yaml
diagrid appid update <app-id> --app-config tracing-config
``` 

### Secrets

Catalyst supports **Kubernetes Secrets** (default) and **AWS Secrets Manager**.

To use AWS Secrets Manager:

```yaml
global:
  secrets:
    provider: "aws_secretmanager"
    aws:
      region: "us-east-1"
```

### App Tunnels

App tunnels (via Piko) connect Catalyst to applications on private networks without needing to expose them. Tunnels are always secured with mTLS. To enable TLS for the proxy connection itself:

```yaml
piko:
  enabled: true
  certificates:
    proxy:
      enabled: true
      secretName: "piko-proxy-tls"
```

## Networking

Catalyst Private requires outbound connectivity to Diagrid Cloud. Ensure your network allows access to:

| Domain | Description | Required |
|--------|-------------|----------|
| `api.r1.diagrid.io` | Region join (installation only). | Yes |
| `catalyst-cloud.r1.diagrid.io` | Resource configuration updates. | Yes |
| `sentry.r1.diagrid.io` | Workload identity (mTLS). | Yes |
| `trust.r1.diagrid.io` | Trust anchors (mTLS). | Yes |
| `tunnels.trust.diagrid.io` | OIDC provider for Piko tunnels. | No |
| `client-events.r1.diagrid.io` | Event publishing. | Yes |
| `catalyst-metrics.r1.diagrid.io` | Dapr runtime metrics. | No |
| `catalyst-logs.r1.diagrid.io` | Dapr sidecar logs. | No |

**Note:** mTLS is used for secure communication. Ensure your proxy/firewall does not inspect this traffic.

### Network Policies

By default Catalyst sidecars have their traffic restricted using Kubernetes Network Policies. External access is blocked
to the following CIDRs through the `agent.config.project.blocked_cidrs` Helm value:

```yaml
agent:
  config:
    project:
      blocked_cidrs:
        - "10.0.0.0/8",
        - "172.16.0.0/12",
        - "192.168.0.0/16"
```

This can be customized as needed to fit your environment.

## Development

### Build Dependencies

```bash
make helm-prereqs
```

### Testing

```bash
make helm-test          # Unit tests
make helm-lint          # Linting
make helm-template      # Render templates
make helm-validate      # Validation
```

### Dependency Management

Update `Chart.yaml`, then run:

```bash
helm dependency update
```

## Documentation

- [Catalyst Documentation](https://docs.diagrid.io/catalyst)
- [Catalyst Support](https://docs.diagrid.io/catalyst/support)
- [Diagrid Website](https://www.diagrid.io/)
- [Diagrid Support](https://diagrid.io/support)
