# Catalyst Helm Chart

## Overview

Diagrid Catalyst is a collection of API-based programming patterns for messaging, data, and workflow that is fully compliant with the Dapr open source project. It provides managed components and runtime that streamline cloud-native application development.

![Catalyst](../../assets/img/catalyst.svg)

A Catalyst installation consists of the following components:
- **Agent**: Manages the configuration of Dapr projects.
- **Management**: Provides access to service providers such as secrets stores.
- **Gateway**: Provides routing to Dapr runtime instances.
- **Telemetry**: Collectors export telemetry from Dapr.
- **Piko**: Provides tunnels to connect to applications on private networks.

## Guides
For step-by-step guides on deploying Catalyst to various Kubernetes environments, please refer to the following:

- [Deploying Catalyst to a KinD Cluster](./guides/kind/README.md)
- [Deploying Catalyst to an Azure Kubernetes Service Cluster](./guides/azure/README.md)
- [Deploying Catalyst to an AWS Elastic Kubernetes Service Cluster](./guides/aws/README.md)

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
     --set join_token="${JOIN_TOKEN}"
```

## Uninstall
To uninstall Catalyst and clean up all associated resources, run the following command:

```bash
helm uninstall catalyst -n cra-agent
```

> **WARNING:**  The `region` resource is intended for a single installation, once you uninstall Catalyst, the region is no longer valid.
If you want to uninstall Catalyst but allow re-installation, remove the clean up hook by setting the values:

```bash
cleanup:
  enabled: false
```

## Configuration

### Images

The Catalyst Helm chart deploys multiple container images across its components. This section documents all images used by the chart to help users understand what will be installed and what images may need to be mirrored to private registries.

### Installation Images

By default, the chart uses a consolidated Catalyst image that includes all necessary components:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Catalyst** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/catalyst-all:<tag>` | Catalyst services |

It is possible to run the chart with separate images for each component:
| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Catalyst Agent** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/cra-agent:<tag>` | Catalyst agent service |
| **Catalyst Management** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/catalyst-management:<tag>` | Catalyst management service |
| **Gateway Control Plane** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/catalyst-gateway:<tag>` | Gateway control plane service |
| **Gateway Identity Injector** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/identity-injector:<tag>` | Identity injection service |

Catalyst also uses the following dependency images:
| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Envoy Proxy** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-hub-proxy/envoyproxy/envoy:<tag>` | Envoy proxy for gateway |
| **Piko** | `ghcr.io/andydunstall/piko:<tag>` | Piko reverse tunneling service |

### Runtime Images

The Catalyst Agent provisions additional images at runtime, including:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Dapr Server** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/sidecar:<tag>` | Catalyst dapr server |
| **OpenTelemetry Collector** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/diagrid-otel-collector:<tag>` | OTel collector for telemetry |
| **Dapr Control Plane (OSS)** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-hub-proxy/daprio/dapr:<tag>` | Dapr control plane services (operator, placement, sentry, scheduler) |
| **Dapr Control Plane (Catalyst)** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/dapr:<tag>` | Catalyst Dapr control plane services (operator, placement, sentry, scheduler) |

### Mirroring Images to a Private Registry

If you're deploying in an air-gapped environment or need to use a private registry, you can use the provided mirror script to copy all images.

The script is located at `scripts/catalyst/mirror-images.sh` and handles pulling all Catalyst images and pushing them to your private registry.

**Basic usage with current versions:**

```bash
./scripts/catalyst/mirror-images.sh my-registry.example.com \
  --catalyst-version 0.469.0 \
  --dapr-version 1.16.1 \
  --internal-dapr-version 1.16.2-rc.1-catalyst.2 \
  --envoy-version distroless-v1.33.0 \
  --piko-version v0.8.1
```

After mirroring, configure your values file with the global registry override pointing to your private registry:

```yaml
global:
  image:
    registry: my-registry.example.com
```

## Dapr PKI

Dapr has a control plane component called [Sentry](https://docs.dapr.io/concepts/dapr-services/sentry/) that issues identity credentials (X.509 certificates) to Dapr sidecars and other Dapr control plane services. By default, Sentry generates a self-signed root certificate authority (CA) to sign these certificates that is valid for 1 year. It is strongly recommended that you integrate with your own PKI solution. This can be done by providing an issuer (or intermediate) CA certificate and private key, as well as trust anchors (or root CA certificates) to the Dapr Sentry component. Use the following configuration in your Catalyst Helm Chart `values.yaml` to set up Dapr PKI with Catalyst:

```yaml
agent:
  config:
    internal_dapr:
      ca:
        issuer_secret_name: "issuer-secret" # Name of the Kubernetes TLS Secret containing the CA issuer certificate and private key
        trust_anchors_config_map_name: "trust-anchors" # Name of the Kubernetes ConfigMap containing the CA trust anchors
        namespace: "cra-agent" # Namespace where the CA resources are located
```

## Gateway TLS

If you wish to terminate TLS at the Catalyst Gateway, you can provide your own TLS certificate and private key using the following configuration in your Catalyst Helm Chart `values.yaml`.

### Using an Existing TLS Secret

For an existing TLS secret:
```yaml
gateway:
  tls:
    enabled: true
    existingSecret: "my-tls-secret" # Name of the existing Kubernetes Secret containing the TLS certificate and private key
```

### Using Inline Certificate and Key

You can also provide the certificate and key inline or via file references:

```yaml
gateway:
  tls:
    enabled: true
    cert: |
      -----BEGIN CERTIFICATE-----
      MIIDXTCCAkWgAwIBAgIJALN3fF8NqLxeMA0GCSqGSIb3DQEBCwUAMEUxCzAJBgNV
      ...
      -----END CERTIFICATE-----
    key: |
      -----BEGIN PRIVATE KEY-----
      MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC5Ym8qkGZgGfWE
      ...
      -----END PRIVATE KEY-----
```

## OpenTelemetry Collector (Optional)

Catalyst includes optional OpenTelemetry Collector addons that provide a flexible, vendor-neutral way to collect and export telemetry data (logs, metrics, and traces) from your Kubernetes cluster.

### Why Use the OpenTelemetry Collector?

- **Vendor Neutrality**: Send telemetry to any backend that supports OTLP or other standard protocols
- **Flexibility**: Configure different exporters for traces, metrics, and logs independently
- **Efficiency**: Process and filter telemetry before export to reduce costs and noise
- **Standardization**: Use industry-standard OpenTelemetry instrumentation across all applications

For more information on how to configure the OpenTelemetry Collector, visit the [official documentation](https://opentelemetry.io/docs/collector/configuration/).

## Development

If you're developing or testing this chart locally from source:

### Build Dependencies

Before testing or deploying the chart from source, build the chart dependencies:

```bash
# Add required Helm repositories
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# Build dependencies
helm dependency build
```

Alternatively, use the Makefile from the repository root:

```bash
make helm-prereqs
```

### Testing

```bash
# From repository root
make helm-test          # Run unit tests
make helm-lint          # Run linting
make helm-template      # Render templates
make helm-validate      # Run all validation
```

### Dependency Management

The `Chart.lock` file tracks exact dependency versions for reproducible builds. When modifying dependencies:

1. Update `Chart.yaml` with changes
2. Run `helm dependency update` to regenerate `Chart.lock`
3. Commit both files to version control

## Documentation

For more information about Diagrid Catalyst, including detailed usage instructions and examples, please visit:

- [Catalyst Documentation](https://docs.diagrid.io/catalyst)
- [Catalyst Support](https://docs.diagrid.io/catalyst/support)
- [Diagrid Website](https://www.diagrid.io/)
- [Diagrid Support](https://diagrid.io/support)
- [OpenTelemetry Collector Documentation](https://opentelemetry.io/docs/collector/)
- [OpenTelemetry Collector Helm Chart](https://github.com/open-telemetry/opentelemetry-helm-charts/tree/main/charts/opentelemetry-collector)
- [Collector Configuration Reference](https://opentelemetry.io/docs/collector/configuration/)
