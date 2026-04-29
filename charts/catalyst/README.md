# Catalyst Helm Chart Reference

Configuration reference for the Catalyst Helm chart.

## Prerequisites

- Kubernetes 1.20+
- [Helm](https://helm.sh/) v3.12.0+
- [Diagrid CLI](https://docs.diagrid.io/catalyst/references/cli-reference/intro)

## Chart Dependencies

This chart includes the following dependencies:

- **OpenTelemetry Collector** — Optional telemetry collection and export

## Install

```bash
helm install catalyst oci://public.ecr.aws/diagrid/catalyst \
     -n cra-agent \
     --create-namespace \
     -f catalyst-values.yaml \
     --set join_token="${JOIN_TOKEN}"
```

`JOIN_TOKEN` must be obtained from Diagrid Cloud before installing. See the [Getting Started guide](../../guides/getting-started/README.md) for signup and token retrieval.

## Uninstall

```bash
helm uninstall catalyst -n cra-agent
```

> **WARNING:** The `region` resource is intended for a single installation, once you uninstall Catalyst, the region is no longer valid. If you want to uninstall Catalyst but allow re-installation, remove the clean up hook by setting the values:

```yaml
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
| **Piko** | `$REPO/diagrid-piko:<tag>` | Piko reverse tunneling service |

#### Runtime Images

The Agent provisions these at runtime:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Dapr Server** | `$REPO/sidecar:<tag>` | Catalyst dapr server |
| **OpenTelemetry Collector** | `$REPO/catalyst-otel-collector:<tag>` | OTel collector for telemetry |
| **Dapr Control Plane (Catalyst)** | `$REPO/dapr:<tag>` | Catalyst Dapr control plane services |
| **Dapr Control Plane (OSS)** | `daprio/dapr:<tag>` | Dapr control plane services |

#### Optional Images

Used when OpenTelemetry addons are enabled:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **OpenTelemetry Collector (OSS)** | `ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-k8s:<tag>` | Collector for traces, metrics, and logs |

### Private Image Registry

Point the chart at a mirrored registry:

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

For the full mirror procedure (including the `mirror-images.sh` script) see the [Air-gapped installs guide](../../guides/air-gapped/README.md).

### Private Helm Registry

Configure chart registry authentication:

```yaml
global:
  charts:
    registry: "oci://my-registry.example.com/diagrid/catalyst"
    username: "my-username"
    password: "my-password"
    # Or use existingSecret, clientCert, clientKey, customCA
```

See the [Air-gapped installs guide](../../guides/air-gapped/README.md) for the steps to mirror the chart itself.

### Dapr PKI

By default, Dapr Sentry generates a self-signed root CA. For production, integrate with your own PKI by providing an issuer CA and trust anchors:

```yaml
agent:
  config:
    internal_dapr:
      pki:
        issuer:
          secret:
            name: dapr-trust-bundle
            namespace: cert-manager
            cert: tls.crt
            key: tls.key
        trust:
          config_map:
            name: dapr-trust-bundle
            namespace: cert-manager
            chain: ca.crt
```

For an end-to-end walkthrough using `cert-manager` and `trust-manager` to provision these certificates, see the [Dapr PKI guide](../../guides/dapr-pki/README.md).

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

For step-by-step instructions covering self-signed (dev), bring-your-own certificates, cert-manager integration, private CA trust for sidecars, and rotation, see the [Gateway TLS guide](../../guides/gateway-tls/README.md).

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

To emit traces from Dapr apps into the collector (or any other OTLP backend), see the [tracing guide](../../guides/tracing/README.md) — tracing is enabled per App ID via the Diagrid CLI, not through chart values.

### Secrets

Catalyst supports four secret provider backends: **Kubernetes Secrets** (default), **AWS Secrets Manager** and **PostgreSQL**.

To use AWS Secrets Manager:

```yaml
global:
  secrets:
    provider: "aws.secretmanager"
    aws:
      region: "us-east-1"
```

#### PostgreSQL Secrets Provider

The PostgreSQL secrets provider stores Catalyst application secrets in a PostgreSQL database using envelope encryption (each secret is encrypted with a data encryption key, which is itself encrypted by a key encryption key).

**Inline configuration** (connection string and keys provided directly in values):

```yaml
global:
  secrets:
    provider: postgresql
    postgresql:
      kek_provider: "local"           # "local" (AES-256) or "awskms" (AWS KMS)
      connection_string: "postgres://user:password@host:5432/dbname"
      primary_encryption_key: "<64 hex characters>"
      primary_key_version: 1
```

**Using an existing Kubernetes secret** (recommended for production — keeps all sensitive config out of values files):

First, create the Kubernetes secret in the same namespace as the Catalyst installation:

```bash
kubectl create secret generic catalyst-pg-secrets -n cra-agent \
  --from-literal=connection_string="postgres://user:password@host:5432/dbname" \
  --from-literal=kek_provider="local" \
  --from-literal=primary_encryption_key="<64 hex characters>" \
  --from-literal=primary_key_version="1"
```

Then reference it in values:

```yaml
global:
  secrets:
    provider: postgresql
    postgresql:
      existingSecret: "catalyst-pg-secrets"
```

>NOTE: When `existingSecret` is set, **all** PostgreSQL secrets provider config is read from the referenced Kubernetes secret via environment variables — nothing is written to the ConfigMap. All keys are read with `optional: true`, so keys that are absent from the secret are simply not set and the application uses its built-in defaults (useful for optional fields like secondary keys or AWS KMS config). By default the secret key names match the config field names. Override individual key names using `existingSecretKeys` if your secret uses different naming:

```yaml
global:
  secrets:
    postgresql:
      existingSecret: "catalyst-pg-secrets"
      existingSecretKeys:
        connection_string: "pg_conn_str"
        primary_encryption_key: "kek_primary"
        primary_key_version: "kek_primary_version"
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

Catalyst Enterprise Self-Hosted requires outbound connectivity to Diagrid Cloud. Ensure your network allows access to:

| Domain | Description | Required |
|--------|-------------|----------|
| `api.r1.diagrid.io` | Region join (installation only). | Yes |
| `catalyst-cloud.r1.diagrid.io` | Resource configuration updates. | Yes |
| `sentry.r1.diagrid.io` | Workload identity (mTLS). | Yes |
| `trust.r1.diagrid.io` | Trust anchors (mTLS). | Yes |
| `tunnels.trust.diagrid.io` | OIDC provider for Piko tunnels. | No |
| `catalyst-metrics.r1.diagrid.io` | Dapr runtime metrics. | No |
| `catalyst-logs.r1.diagrid.io` | Dapr sidecar logs. | No |

**Note:** mTLS is used for secure communication. Ensure your proxy/firewall does not inspect this traffic.

### Network Policies

Catalyst configures Kubernetes `NetworkPolicy` resources per project namespace using three symmetric lists:

| Key | What it does |
|-----|--------------|
| `agent.config.project.blocked_egress`  | Denies destinations in the sidecar `0.0.0.0/0` egress rule. CIDR-only (NetworkPolicy `except` limitation). |
| `agent.config.project.allowed_egress`  | Additive egress allow rules. May target CIDRs and/or namespaces, with optional port scoping. |
| `agent.config.project.allowed_ingress` | Additive ingress allow rules into project namespaces. May target CIDRs and/or namespaces, with optional port scoping. |

**Precedence: allow beats block.** NetworkPolicy rules are additive — the API server OR's them together — so any
destination matched by an `allowed_egress` entry is reachable even if its CIDR also appears in `blocked_egress`. Use
this to punch narrow holes through the block list rather than weakening it.

**Ingress floor (non-configurable):** the agent namespace (`cra-agent`) and the `monitoring` namespace are always
permitted as ingress sources. Management and Prometheus scraping therefore never break regardless of `allowed_ingress`.

#### Default block list

```yaml
agent:
  config:
    project:
      blocked_egress:
        - name: rfc1918
          cidrs:
            - "10.0.0.0/8"
            - "172.16.0.0/12"
            - "192.168.0.0/16"
        - name: link-local           # covers cloud instance metadata endpoints
          cidrs:
            - "169.254.0.0/16"
```

Trim entries or replace the whole list to match your environment (e.g. on GKE/AKS the pod network lives inside
`10.0.0.0/8`; prefer punching allow holes through `allowed_egress` rather than removing the block). Set
`blocked_egress: []` to permit all egress (not recommended for production usage).

#### Allowing specific destinations

Both `cidrs` and `namespaces` may be set on the same rule. Ports are optional and default to "all ports" when omitted:

```yaml
agent:
  config:
    project:
      allowed_egress:
        - name: rds
          cidrs: ["10.4.5.6/32"]
          ports:
            - port: 5432
              protocol: TCP
        - name: msk
          cidrs: ["10.4.5.0/24"]
          ports:
            - port: 9094
              protocol: TCP
        - name: worker-namespace
          namespaces: ["my-workers"]
```

#### Allowing ingress

```yaml
agent:
  config:
    project:
      allowed_ingress:
        - name: extra-prom
          namespaces: ["observability"]
          ports:
            - port: 9090
              protocol: TCP
```

#### Disabling network policies entirely

```yaml
agent:
  config:
    project:
      disable_network_policies: true
```

When disabled, no `NetworkPolicy` resources are created for project namespaces, and any previously created policies are
removed on the next reconcile.

> **CNI requirement:** NetworkPolicy enforcement requires a CNI that supports it (Calico, Cilium, Azure NPM, AWS VPC
> CNI with `ENABLE_NETWORK_POLICY=true`, or kube-router). If none is detected at startup the agent logs a warning and
> policies are still created altough not enforced.

## Documentation

- [Catalyst Documentation](https://docs.diagrid.io/catalyst)
- [Catalyst Support](https://docs.diagrid.io/catalyst/support)
- [Diagrid Website](https://www.diagrid.io/)
- [Diagrid Support](https://diagrid.io/support)
