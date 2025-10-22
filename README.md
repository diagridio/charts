# Diagrid Helm Charts Repository

This repository contains official Helm charts published by Diagrid for deploying Diagrid products on Kubernetes.

> ⚠️ This repository is under active development. Documentation may be updated frequently.


## Available Charts

### Catalyst ⚡️

https://catalyst.diagrid.io

Diagrid Catalyst is a collection of API-based programming patterns for messaging, data, and workflow that is fully compliant with the Dapr open source project. It provides managed components and runtime that streamline cloud-native application development.

![Catalyst](./assets/img/catalyst.svg)

A Catalyst installation consists of the following components:
- **Agent**: Manages the configuration of Dapr projects.
- **Management**: Provides access to service providers such as secrets stores.
- **Gateway**: Provides routing to Dapr runtime instances.
- **Telemetry**: Collectors export telemetry from Dapr.
- **Piko**: Provides tunnels to connect to applications on private networks.

## Guides

- [Deploying Catalyst to a KinD Cluster](./guides/kind/README.md)
- [Deploying Catalyst to an Azure Kubernetes Service Cluster](./guides/azure/README.md)
- [Deploying Catalyst to an AWS Elastic Kubernetes Service Cluster](./guides/aws/README.md)

## Docs

For more information about Diagrid Catalyst, including detailed usage instructions and examples, please visit:

- [Catalyst Documentation](https://docs.diagrid.io/catalyst)
- [Catalyst Support](https://docs.diagrid.io/catalyst/support)
- [Diagrid Website](https://www.diagrid.io/)
- [Diagrid Support](https://diagrid.io/support)

## Images

The Catalyst Helm chart deploys multiple container images across its components. This section documents all images used by the chart to help users understand what will be installed and what images may need to be mirrored to private registries.

### Default Image Configuration

By default, the chart uses separate images for each component:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Catalyst Agent** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/cra-agent:<tag>` | Catalyst agent service |
| **Catalyst Management** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/catalyst-management:<tag>` | Catalyst management service |
| **Gateway Control Plane** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/catalyst-gateway:<tag>` | Gateway control plane service |
| **Gateway Identity Injector** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/identity-injector:<tag>` | Identity injection service |
| **Envoy Proxy** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-hub-proxy/envoyproxy/envoy:<tag>` | Envoy proxy for gateway |
| **Piko** | `ghcr.io/andydunstall/piko:<tag>` | Piko reverse tunneling service |

### Agent Nested Images

The Catalyst agent configuration includes additional images for sidecars and dependencies:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Sidecar** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/sidecar:<tag>` | Catalyst sidecar injected into workloads |
| **OpenTelemetry Collector** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/diagrid-otel-collector:<tag>` | OTel collector for telemetry |
| **vcluster k0s** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-hub-proxy/k0sproject/k0s:<tag>` | k0s distribution for vcluster |
| **CoreDNS** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-hub-proxy/coredns/coredns:<tag>` | CoreDNS for vcluster |

**Upstream Dapr Images** (from `upstream_dapr.container_registry`):

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Dapr Control Plane** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-hub-proxy/daprio/dapr:<tag>` | Dapr control plane services (operator, placement, sentry, scheduler) |

**Internal Dapr Images** (from `internal_dapr.container_registry`, Catalyst-modified):

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Catalyst Dapr Control Plane** | `us-central1-docker.pkg.dev/prj-common-d-shared-89549/reg-d-common-docker-public/dapr:<tag>` | Internal Dapr control plane services (operator, placement, sentry, scheduler) |

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
  --piko-version v0.8.1 \
  --k0s-version v1.26.0-k0s.0 \
  --coredns-version 1.10.1
```

After mirroring, configure your values file with the global registry override pointing to your private registry:

```yaml
global:
  image:
    registry: my-registry.example.com
```

## Contributing

We welcome contributions to our Helm charts. Please feel free to submit issues or pull requests.

## License

Copyright © Diagrid, Inc.
