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

Catalyst should be installed in a dedicated Kubernetes cluster. It manages global resources and dynamically provisions workloads, which may conflict with other applications in a shared cluster. If you must install into a shared cluster, you must ensure the cluster-wide permissions described in the [RBAC section](#permissions-rbac) are acceptable for your setup or consider using a cluster virtualization solution like [vcluster](https://github.com/loft-sh/vcluster).

### Network Policies

Catalyst always generates NetworkPolicies for **project namespaces** (deny-all plus explicit allows, created by the agent at provisioning time). The **system namespaces** — the release namespace and the internal Dapr namespace — ship without policies by default. On clusters with a default-deny security mandate, enable the chart-managed set:

```yaml
networkPolicies:
  enabled: true
```

This installs deny-all policies for both system namespaces plus the explicit allows Catalyst needs: intra-namespace traffic, project-sidecar access to piko/management and the Dapr control plane, public ingress to the gateway, and egress to DNS, the Kubernetes API server, the Diagrid control plane (public internet except private ranges — standard NetworkPolicy cannot match hostnames), and project namespaces.

These policies only take effect on clusters whose CNI enforces NetworkPolicy (Calico, Cilium, Azure NPM, ...). Without one they are silently inert — the agent logs a warning at startup when no enforcing CNI is detected.

Install-specific values:

```yaml
networkPolicies:
  enabled: true
  # NetworkPolicy is evaluated after kube-proxy DNAT, so API server traffic is
  # matched against the real endpoint (kubectl get endpoints kubernetes -n default),
  # never the kubernetes.default ClusterIP. Unset, the policy falls back to
  # allowing all private ranges on ports 443 and 6443.
  apiserver:
    endpointCIDR: "10.224.0.4/32"
    port: 443
  # Allows agent egress to an in-cluster PostgreSQL on 5432 (scheduler and
  # managed state store databases). Omit when not using postgres-backed features.
  postgres:
    namespace: "postgres"
  # Extra egress allows for private destinations (VNet databases, private
  # endpoints) that the internet-egress policy's private-range excepts block.
  extraEgress:
    - cidr: 10.100.0.0/24
      ports:
        - port: 5432
```

If the PostgreSQL namespace is itself default-deny, its ingress allows are yours to manage: both the release namespace (agent) and every project namespace (sidecars connect directly for managed state stores) need ingress on 5432.

### Permissions (RBAC)

Catalyst is a self-managing infrastructure platform: not a static set of workloads, the Catalyst **agent** acts as an in-cluster provisioner that creates and manages a Dapr control plane, dapr sidecars, dapr CRDs, and optionally supporting infrastructure (Kafka, PostgreSQL, Redis, vcluster, sandboxes) **on demand** as you create Catalyst projects and resources. Because the exact resource set and target namespaces are decided at runtime, not at install time, the agent is granted a **cluster-scoped** role. The management and gateway components are scoped more narrowly.

Depending on your use case and installation, you may be able to remove some of the permissions provided in the default config but this must be done with caution on a case by case basis to avoid breaking functionality.

The Catalyst Helm chart creates 4 RBAC subjects. The tables below justify each grant so cluster operators can review the blast radius before installing.

#### 1. Agent

> 🗒️ The Catalyst Agent installs a Catalyst distribution of Dapr and thus must satisfy the permissions required by that. Many of the agent permissions are simply to align with Dapr's own RBAC permissions.

The agent's ServiceAccount (`<release>-agent-sa`, e.g. `catalyst-agent-sa`) carries the broadest permissions because it installs charts into, and reconciles resources across, many namespaces (`cra-agent`, `root-dapr-system`, `shared-{kafka,postgresql}`, per-project `prj-*`, and `default`).

| API group | Resources | Verbs | Why it is required |
|-----------|-----------|-------|--------------------|
| `""` | `namespaces` | get, list, watch, create and delete | Reconcile project namespaces. `create`/`delete` are granted only when the agent owns the namespace lifecycle; set `agent.config.project.externally_managed_namespaces: true` to drop them when an external owner pre-provisions namespaces. `watch` is also needed for no-escalation against the Dapr chart. |
| `""` | `configmaps`, `secrets`, `services`, `serviceaccounts` | full CRUD | These are created by the Dapr, vcluster, OTel, Kafka, PostgreSQL, Redis, CRA sidecar, component, and namespace charts. The agent also reads image-pull secrets / infra passwords from arbitrary namespaces and syncs pull secrets into project namespaces. |
| `""` | `pods` | get, list, watch, delete | Helm `--wait` polls pod readiness during install/upgrade (the agent never creates pods directly). `delete` is required for no-escalation against the Dapr chart. |
| `""` | `pods/log` | get | The on-error handler reads pod logs to surface install/upgrade failure details. |
| `""` | `persistentvolumeclaims` | get, delete, deletecollection | Teardown of Dapr scheduler/placement StatefulSet PVCs (by label selector) and, on boot, detecting an orphaned `shared-postgresql` data directory so a fresh admin password is never seeded against an existing database. |
| `""` | `events` | create, patch | Helm emits Kubernetes events during chart operations. |
| `""` | `services/finalizers` | get, list, watch, create, update | No-escalation against the Dapr chart (`dapr-operator-admin`). |
| apps | `deployments`, `statefulsets`, `daemonsets` | full CRUD | The actual workloads installed by the Dapr control plane, OTel collectors, Kafka, PostgreSQL, Redis, and CRA sidecar charts. `deployments` also needs `patch` to restart sidecars on trust-bundle rotation. |
| apps | `replicasets` | get, list, watch | Owned by Deployments; read by Helm `--wait`. |
| apps | `deployments/finalizers`, `statefulsets/finalizers` | get, list, watch, update | No-escalation against the Dapr chart. |
| authentication.k8s.io | `tokenreviews` | create | No-escalation against `dapr-sentry`, which validates workload tokens. |
| autoscaling | `horizontalpodautoscalers` | full CRUD | HPA installed by the CRA sidecar chart. |
| policy | `poddisruptionbudgets` | full CRUD | PDBs installed by the Dapr chart. |
| batch | `cronjobs`, `jobs` | full CRUD | The Dapr JWT key-rotation chart. |
| networking.k8s.io | `networkpolicies` | full CRUD | Per-project egress/ingress policies created by the namespace chart (see [Network Policies](#network-policies)). |
| rbac.authorization.k8s.io | `roles`, `rolebindings`, `clusterroles`, `clusterrolebindings` | full CRUD | Per-sidecar Role/RoleBinding (CRA chart) plus the ClusterRoles/Bindings installed by the Dapr chart and the OTel collectors. |
| dapr.io | `components`, `configurations`, `subscriptions`, `resiliencies`, `httpendpoints`, `mcpservers` | full CRUD | Per-project/per-app Dapr resources rendered by the component and resource charts, plus the agent's own bootstrap Configuration. |
| apiextensions.k8s.io | `customresourcedefinitions` | full CRUD | The Dapr (and potentially vcluster) CRDs that Helm applies ahead of templated resources on install/upgrade. |
| admissionregistration.k8s.io | `mutatingwebhookconfigurations`, `validatingwebhookconfigurations` | full CRUD | The Dapr sidecar-injector `MutatingWebhookConfiguration` (validating is included to stay forward-compatible with future chart versions). |
| discovery.k8s.io | `endpointslices` | get | Reads the `kubernetes` service EndpointSlice in `default` to build NetworkPolicy rules that allow access to the API server. |
| agents.x-k8s.io | `sandboxes` | full CRUD | The upstream `kubernetes-sigs/agent-sandbox` CRs the gVisor sandbox provider materializes per project. |
| node.k8s.io | `runtimeclasses` | get | The gVisor sandbox provider's preflight check verifies the configured RuntimeClass is registered before creating any Sandbox. `get` only — read once at boot. |
| coordination.k8s.io | `leases` | full CRUD | Leader election for the agent itself. |

#### 2. Management Service

The management service watches resources across all project namespaces, so its role is cluster-scoped — but it is almost entirely read-only.

| API group | Resources | Verbs | Why it is required |
|-----------|-----------|-------|--------------------|
| `""` | `configmaps` | get, list, watch, patch | Informer cache (list/watch) plus `patch` to write external-resource-sync (xrs) ACK annotations and `get` region details. |
| `""` | `secrets` | get, list, watch, create, update, delete | Informer cache plus CRUD on the per-project / per-App-ID API token secrets it manages. |
| `""` | `namespaces` | get, list | Look up the namespace backing a given project. |
| coordination.k8s.io | `leases` | get, create, update | Leader election. |
| dapr.io | `components` | get, list, watch | Component lookup and Kafka topology resolution. |
| dapr.io | `configurations` | get, list, watch | Read-only Configuration lookup. |

#### 3. Gateway Control Plane

The gateway control plane needs only a narrow cluster-wide read for service discovery; everything it writes is confined to the release namespace.

**`ClusterRole` + `ClusterRoleBinding` (cluster-wide):**

| API group | Resources | Verbs | Why it is required |
|-----------|-----------|-------|--------------------|
| discovery.k8s.io | `endpointslices` | get, list, watch | Discover backend endpoints to route traffic to. |
| `""` | `services` | get, list, watch | Resolve the Services those endpoints belong to. |

**`Role` + `RoleBinding` (release namespace only):**

| API group | Resources | Verbs | Why it is required |
|-----------|-----------|-------|--------------------|
| coordination.k8s.io | `leases` | get, list, watch, create, update, delete | Leader election among gateway replicas. |
| `""` | `secrets` | get, list | Read its own TLS / config secrets. |
| `""` | `configmaps` | get, list, watch, create, update, patch | Persist the `controlplane-cache` ConfigMap (Region/Certificate specs) so the leader can recover to a last-known-good state during a controlplane outage. |
| dapr.io | `configurations` | get | *(only when `global.waitForDaprConfig.enabled`, the default)* The `wait-for-dapr-config` init container blocks startup until the agent has created the Configuration CR referenced by the pod's `dapr.io/config` annotation. A second, equivalent `Role`/`RoleBinding` is created for the **gateway envoy** ServiceAccount for the same init container. |

#### 4. Cleanup hook (optional)

When `cleanup.enabled` is `true` (the default), `helm uninstall` runs a `post-delete` Job that tears down everything the agent provisioned at runtime — Dapr/OTel Helm releases, the Dapr namespace, and any `cra.diagrid.io/project-namespace=true` namespaces. Its RBAC objects carry `helm.sh/hook-delete-policy: hook-succeeded,hook-failed`, so they exist only for the duration of the uninstall and are then removed.

| API group | Resources | Verbs | Why it is required |
|-----------|-----------|-------|--------------------|
| `""` | `namespaces` | get, list, delete | Delete the Dapr namespace and Catalyst-created project namespaces. |
| `""` | `secrets`, `services`, `configmaps`, `serviceaccounts`, `persistentvolumeclaims` | get, list, delete, update | Remove leftover resources from uninstalled releases. |
| apps | `deployments`, `statefulsets`, `replicasets`, `daemonsets` | get, list, delete | Remove provisioned workloads. |
| batch | `jobs`, `cronjobs` | get, list, delete | Remove provisioned batch workloads. |
| policy | `poddisruptionbudgets` | get, list, delete | Remove PDBs left by the Dapr chart. |
| apiextensions.k8s.io | `customresourcedefinitions` | get, list, delete | Remove Dapr CRDs. |
| rbac.authorization.k8s.io | `clusterroles`, `clusterrolebindings`, `roles`, `rolebindings` | get, list, delete | Remove RBAC objects created by provisioned charts. |
| admissionregistration.k8s.io | `mutatingwebhookconfigurations`, `validatingwebhookconfigurations` | get, list, delete | Remove the Dapr sidecar-injector webhook. |
| dapr.io | `*` | get, list, delete | Remove all Dapr custom resources. |

Set `cleanup.enabled: false` to skip this hook (and its RBAC) entirely — note this also leaves the `region` resource intact for re-installation, as described under [Uninstall](#uninstall).

### Images

The following images are deployed by the chart. Use this list as a starting point for building a registry allowlist or for mirroring to a private registry.

#### Installation Images

By default, this is the full list of images that are installed in your cluster:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Alpine k8s** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-hub-proxy/alpine/k8s:1.36.0` | Utility image used by Helm install and cleanup hooks |
| **Envoy Proxy** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-hub-proxy/envoyproxy/envoy:distroless-v1.38.0` | Envoy proxy for gateway |
| **Catalyst** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/catalyst-all:1.78.0` | Consolidated Catalyst services image |
| **Piko** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/diagrid-piko:v1.0.1` | Piko reverse tunneling service |
| **Dapr Control Plane (Catalyst)** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/dapr:1.19.0-20260720-catalyst.1` | Catalyst Dapr control plane services |
| **Dapr Server** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/catalyst-all:1.78.0` | Catalyst dapr server |
| **OpenTelemetry Collector** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/catalyst-all:1.78.0` | OTel collector for telemetry |

Alternatively, separate images can be used:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Catalyst Agent** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/cra-agent:1.78.0` | Catalyst agent service |
| **Catalyst Management** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/catalyst-management:1.78.0` | Catalyst management service |
| **Gateway Control Plane** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/catalyst-gateway:1.78.0` | Gateway control plane service |
| **Gateway Identity Injector** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/identity-injector:1.78.0` | Identity injection service |

Dependencies:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Envoy Proxy** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-hub-proxy/envoyproxy/envoy:distroless-v1.38.0` | Envoy proxy for gateway |
| **Piko** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/diagrid-piko:v1.0.1` | Piko reverse tunneling service |
| **Alpine k8s** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-hub-proxy/alpine/k8s:1.36.0` | Utility image used by Helm install and cleanup hooks |

#### Runtime Images

The Agent provisions these at runtime:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Dapr Server** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/sidecar:1.78.0` | Catalyst dapr server |
| **OpenTelemetry Collector** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/catalyst-otel-collector:1.78.0` | OTel collector for telemetry |
| **Dapr Control Plane (Catalyst)** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/dapr:1.19.0-20260720-catalyst.1` | Catalyst Dapr control plane services |

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

### Workload Identity Federation (JWT-SVID Audiences)

Sidecars mint JWT-SVIDs from the public (Diagrid) Sentry that identify the workload by its SPIFFE ID (`spiffe://<region-trust-domain>/ns/<project>/<app-id>`). By default those tokens are audience-scoped to the trust domain. To present a workload's SVID as a **federated credential** to an external identity provider, add the audience that provider expects via `global.sentry.jwt_audiences`:

```yaml
global:
  sentry:
    jwt_audiences:
      - api://AzureADTokenExchange
```

The most common use is **Microsoft Entra ID Workload Identity Federation**. Register a federated identity credential on an App Registration whose `issuer` is the region's public OIDC issuer (e.g. `https://oidc.r1.diagrid.io`), `subject` is the workload's SPIFFE ID, and `audiences` is `api://AzureADTokenExchange`. With that audience configured here, every sidecar the agent provisions receives an SVID that can be exchanged at Azure's token endpoint for an Entra ID access token — no client secret required.

The value applies to all sidecars in the deployment; it is empty by default (no extra audiences, no behavior change).

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

### Pod Scheduling

Every Catalyst workload exposes standard Kubernetes scheduling primitives — `nodeSelector`, `tolerations`, and `affinity` — so you can pin pods to specific node pools or tolerate node taints.

**One knob for everything: `shared.scheduling`**

`shared.scheduling` applies to every pod Catalyst runs or provisions:

- **Control-plane pods** the chart renders directly: agent, management, gateway.envoy, gateway.controlplane, piko.
- **Dapr sidecars** the agent provisions per app.
- **Per-project Dapr control plane** (sentry, scheduler, operator, placement) the agent provisions per project.
- **Per-project OTel collectors** (metrics Deployment + logs DaemonSet) the agent provisions.

Pin everything to one pool with a single block:

```yaml
shared:
  scheduling:
    nodeSelector:
      workload: catalyst
    tolerations:
      - key: workload
        operator: Equal
        value: catalyst
        effect: NoSchedule
```

**Per-workload overrides**

For cases where one workload needs different scheduling from the rest, set a per-workload block. Merge rules (consistent everywhere):
- `nodeSelector` and `affinity` (maps): per-workload wins over `shared.scheduling` on key collision.
- `tolerations` (list): per-workload is appended to `shared.scheduling.tolerations`.

Control-plane per-component overrides:

| Workload | Path |
|---|---|
| agent | `agent.{nodeSelector,tolerations,affinity}` |
| management | `management.{nodeSelector,tolerations,affinity}` |
| gateway envoy | `gateway.envoy.{nodeSelector,tolerations,affinity}` |
| gateway control plane | `gateway.controlplane.{nodeSelector,tolerations,affinity}` |
| piko | `piko.{nodeSelector,tolerations,affinity}` |

Agent-provisioned per-workload overrides:

| Workload | Path |
|---|---|
| Dapr sidecars | `agent.config.sidecar.{node_selector,tolerations,affinity}` |
| Per-project Dapr control plane | `agent.config.internal_dapr.{node_selector,tolerations,affinity}` |
| Per-project OTel collectors | `agent.config.otel.{node_selector,tolerations,affinity}` |

Example — pin everything to one pool, but also spread the gateway across nodes:

```yaml
shared:
  nodeSelector: { workload: catalyst }
  tolerations:
    - { key: workload, operator: Equal, value: catalyst, effect: NoSchedule }

gateway:
  envoy:
    affinity:
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels:
                  app: gateway-envoy
              topologyKey: kubernetes.io/hostname
```

**Caveats worth knowing**

- **Sidecar `affinity` override replaces the default pod anti-affinity.** When `agent.config.sidecar.affinity` is unset, the cra chart spreads sidecar replicas across nodes via a built-in `podAntiAffinity`. Setting `affinity` replaces that block entirely — include an equivalent `podAntiAffinity` in your override if you want to keep the spread.
- **Sidecar tolerations are always appended to platform-managed ones.** The free-plan spot toleration (`diagrid.dev/spot`) is appended on top of shared + per-workload tolerations when the sidecar is scheduled on spot.
- **Affinity map-merge is shallow.** If `shared.affinity` has `nodeAffinity` and a per-workload block sets `podAntiAffinity`, both end up on the pod. If both set the same top-level key (e.g. both set `nodeAffinity`), the per-workload value replaces shared's.
- **For agent-provisioned workloads (sidecar, internal_dapr, otel), prefer `matchExpressions` over `matchLabels` inside affinity** when your label keys contain `.` (e.g. `kubernetes.io/arch`). The agent's config loader (viper) treats `.` as a path separator, so dotted keys inside `matchLabels` get split. Chart-rendered workloads (agent, management, gateway, piko) don't have this constraint.

**Shared OTel subcharts** (the optional `opentelemetry-deployment` and `opentelemetry-daemonset` subcharts at the chart root) accept the same keys and pass them through to the upstream open-telemetry Helm subchart:

```yaml
opentelemetry-deployment:
  enabled: true
  nodeSelector: { workload: catalyst }
```

See the [Kubernetes scheduling docs](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/) for the full field reference.

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

### Sidecar Outbound TLS Trust

The `gateway.tls` settings above cover TLS *into* the region. To let the Dapr sidecars trust upstreams they connect *out* to — MCP servers, external HTTP endpoints, service invocation, bindings — that terminate TLS with a **private or self-signed CA**, add the CA to the sidecars' trust via `agent.config.sidecar`.

These CAs are **added** to the public root bundle baked into the sidecar image (via `SSL_CERT_DIR`), so public-CA upstreams keep working. The trust applies region-wide to every sidecar the agent provisions.

There are two sources, which combine (all listed CAs are trusted when both are set):

**Recommended — reference a Kubernetes ConfigMap** (keeps the PEM out of your Helm values and lets you manage/rotate the CA as a first-class ConfigMap; CA certificates are public data, so a ConfigMap is the natural home):

```yaml
agent:
  config:
    sidecar:
      trusted_ca:
        existing_config_map:
          # ConfigMap holding the CA bundle. Read by the agent at deploy time
          # and mounted into every sidecar.
          name: my-private-ca
          # Optional. Empty = the control plane namespace (where the agent runs).
          namespace: ""
          # Optional. ConfigMap data key holding the PEM. Empty defaults to "ca.crt".
          key: ""
```

**Inline PEM** (suitable for small bundles):

```yaml
agent:
  config:
    sidecar:
      trusted_ca:
        certs:
          - |
            -----BEGIN CERTIFICATE-----
            ...
            -----END CERTIFICATE-----
```

Leave both sources empty to trust only public roots (the default).

### Managed Domain

Set this when you want Diagrid Cloud to allocate the region's public wildcard hostname and TLS certificate for you, instead of bringing your own. Your `--ingress` endpoint then only needs to resolve **locally** (or privately) to the gateway — the controlplane allocates a public wildcard subdomain (under `privatediagrid.net` for Diagrid Cloud) and a matching wildcard certificate, then delivers them to the dataplane.

Use this if you do not want to own a public wildcard DNS zone for the region, or provision and rotate a wildcard TLS certificate for the gateway.

Enable it at region creation time:

```bash
diagrid region create <region-id> --enable-managed-domain --ingress <local-endpoint>
```

With managed domain, `--ingress` is a locally resolvable address (e.g. an internal hostname or an IP). Without it, `--ingress` must be a publicly resolvable wildcard FQDN that you control (e.g. `*.my-region.company.com`).

When managed domain is enabled, you can omit the `gateway.tls` block from your Helm values — the certificate is provisioned by the controlplane and delivered to the dataplane gateway. See [Gateway TLS](#gateway-tls) for the bring-your-own case.

> **Note:** managed domains add a runtime dependency on the controlplane's DNS and certificate-issuance infrastructure. If you require strict isolation from external services, stick with a bring-your-own domain and certificate.

### Data backends (PostgreSQL, Kafka, Redis)

Catalyst relies on data backends shared across a region:

- **PostgreSQL** — backs workflows state and visualizations, AI Agents metadata, managed state components and the Dapr **scheduler** (jobs,
  reminders, cron). Catalyst defaults to automatic self-hosted deployment of PostgreSQL. It is a core part of Catalyst and all the features mentioned previously depend on the database being available. PostgreSQL is also crucial for the performance of workflows.
- **Kafka** — backs managed pub/sub. Catalyst defaults to no deployment, disallowing managed pub/sub brokers to be available on project creation.
- **Redis** — a standalone shared Redis. Disabled by default; provisioned self-hosted in-cluster or connected externally, with optional high availability. Each of the three backends is configured independently and provisioned the same way (self-hosted vs external).

#### Backwards compatibility and upgrades

Helm values for existing installations are honored to keep backwards compatibility for the configuration of the data backends.

The following helm values are **deprecated** but still supported to avoid service disruption.
- `agent.config.project.default_managed_state_store_type`
- `agent.config.project.default_managed_pubsub_type`

We advise to update helm values for existing installations to the new configuration options documented below.

> **Default behaviour change (breaking on upgrade):** Catalyst now uses a **Postgres-backed scheduler**
> by default. Previously the scheduler used an etcd backend.
> By default, on upgrade the scheduler will move from etcd to PostgreSQL.
> **There is no automatic state migration** — existing scheduler jobs/reminders
> held in etcd are not copied to PostgreSQL. If you must keep etcd, opt out explicitly using the values below.
> However we suggest to update scheduler to use the PostgreSQL backend due to its improved performance and reliability.

#### PostgreSQL

```yaml
global:
  postgresql:
    # create: true  -> Catalyst provisions a self-hosted PostgreSQL (default)
    # create: false -> connect to an external PostgreSQL you provide (see .external)
    create: true
    # disabled: true fully turns off the managed PostgreSQL state store (and any
    # Postgres-backed scheduler/workflows). OVERRIDES create.
    disabled: false
```

To use an **external** PostgreSQL (recommended for production), provide the
connection via a Kubernetes secret with keys `host`, `port`, `username`,
`password` (and optionally `proxy_host`):

```yaml
global:
  postgresql:
    create: false
    external:
      auth_type: connectionString
      existing_secret_name: catalyst-postgres
      existing_secret_namespace: catalyst
      disable_tls: false
      max_conns: 2
```

##### Logical replication requirements (external PostgreSQL)

Catalyst uses PostgreSQL **logical replication** (the Postgres-backed scheduler
streams changes via logical decoding). Catalyst's self-hosted PostgreSQL
(`global.postgresql.create: true`) is configured for this automatically. An
**external** database needs two things:

1. **`wal_level = logical`** on the server (requires a restart):

   ```sql
   ALTER SYSTEM SET wal_level = logical;
   ```

   Managed offerings ship it disabled — enable their equivalent instead:

   | Provider | Setting |
   |---|---|
   | Amazon RDS / Aurora | `rds.logical_replication = 1` in the DB parameter group (reboot required) |
   | Google Cloud SQL | `cloudsql.logical_decoding = on` flag |
   | Azure Database for PostgreSQL (Flexible Server) | `wal_level = logical` server parameter (restart required) |

2. **Replication permission** for the user Catalyst connects with:

   ```sql
   ALTER ROLE <username> WITH REPLICATION;
   ```

   On Amazon RDS/Aurora the `REPLICATION` attribute cannot be granted directly —
   use the built-in role instead:

   ```sql
   GRANT rds_replication TO <username>;
   ```

#### Scheduler

The Dapr scheduler persists per-project scheduler state — scheduled jobs, actor
reminders, and workflow triggers. It supports two backends:

| `backend_type` | Where state lives | When to use |
|---|---|---|
| `postgresql` (**default**) | A PostgreSQL database | Almost all cases. Reuses the `global.postgresql` Helm value by default (`use_global: true`). |
| `etcd` | An etcd instance on a PVC | Opt out of PostgreSQL entirely (see below). |

> [!IMPORTANT]
> The PostgreSQL scheduler uses **logical replication** — the database backing it
> (global or dedicated) must meet the
> [logical replication requirements](#logical-replication-requirements-external-postgresql)
> above: `wal_level = logical` plus replication permission for the connecting user.

**PostgreSQL scheduler**

With the default `use_global: true`, the scheduler reuses the global PostgreSQL (`global.postgresql`).
This is the recommended choice for almost all deployments. 
Configure PostgreSQL once (under `global.postgresql`) and the scheduler uses the same database.

```yaml
agent:
  config:
    internal_dapr:
      scheduler:
        backend_type: postgresql   # default 
        postgresql:
          use_global: true         # reuse global.postgresql (recommended)
          max_conns_per_instance: 5
```

> **Requires PostgreSQL to be enabled.** `use_global: true` reuses
> `global.postgresql`, so it cannot be combined with `global.postgresql.disabled: true`.
> If you disable the managed PostgreSQL, switch the scheduler to `etcd` (see below)
> — otherwise rendering fails with a validation error.

**Dedicated scheduler database(s)** — *advanced*

For advanced scenarios where you want the scheduler to use a dedicated
database (or spread across multiple databases) separate from the global
PostgreSQL, set `use_global: false` and provide the connection(s) yourself. Each
entry in `connections` is one scheduler database — supply several to shard the
scheduler across databases.

```yaml
agent:
  config:
    internal_dapr:
      scheduler:
        backend_type: postgresql
        postgresql:
          use_global: false
          max_conns_per_instance: 5
          connections:
            # Inline credentials:
            - host: scheduler-db.example.com
              port: 5432
              username: scheduler
              password: <password>
              database: sched
              disable_ssl_mode: false
            # ...or reference a Kubernetes secret instead of inline credentials:
            - existing_secret_name: scheduler-db-conn
              existing_secret_namespace: db-namespace
```

**ETCD Scheduler**
Opt out of the PosgreSQL scheduler by using in-cluster ETCD with an embedded PVC-backed database. This is not recommended for high-scale, production scenarios.
```yaml
agent:
  config:
    internal_dapr:
      scheduler:
        backend_type: etcd
        storage_size: 8Gi
```

#### Kafka

Managed pub/sub is disabled by default:

```yaml
global:
  kafka:
    # create: true -> self-hosted Kafka; create: false -> external (see .external)
    create: false
    # disabled: true turns managed Kafka off entirely (default). OVERRIDES create.
    disabled: true
    external: {}   # brokers, auth_type, sasl_* when create: false
```

#### Redis

A standalone shared Redis used for caching and key value storage.
This chart version ships it as **opt-in — disabled by default** provisioned in-cluster or connected
externally, and enabled per environment:

```yaml
global:
  redis:
    # create: true -> self-hosted Redis; create: false -> external (see .external)
    create: false
    # disabled: true turns the managed Redis off entirely (default). OVERRIDES create.
    disabled: true
    selfhosted: {}   # persistence_storage_size, replica_count, resources
    external: {}     # host, port, password / existing_secret_name when create: false
```

**High availability** is driven by `selfhosted.replica_count`:

| `replica_count` | Topology |
|---|---|
| `0` (default) | `standalone` — single node, no failover. |
| `>= 1` | `replication` + **Redis Sentinel** — master + N replicas with automatic failover. |

```yaml
global:
  redis:
    create: true
    disabled: false
    selfhosted:
      replica_count: 3            # >=1 enables replication + Sentinel (HA)
      persistence_storage_size: 5Gi
```

To connect to an **external** Redis instead, provide the connection inline or via
an existing Kubernetes secret:

```yaml
global:
  redis:
    create: false
    disabled: false
    external:
      # Inline connection:
      host: redis.example.com
      port: 6379
      disable_tls: false
      # ...or reference an existing secret instead of the inline fields:
      existing_secret_name: catalyst-redis
      existing_secret_namespace: catalyst
```

When `existing_secret_name` is set, the referenced secret must contain the
following keys (the inline `host`/`port`/`username`/`password` fields are then
ignored):

| Key | Required | Description |
|-----|----------|-------------|
| `host` | yes | Redis hostname (without port). |
| `port` | yes | Redis port (e.g. `6379`). |
| `password` | no | Auth password; omit for an unauthenticated Redis. |
| `username` | no | ACL username; omit to use the default user. |

### OpenTelemetry

#### Agent Metrics Export

A **private** region can forward the metrics collected by the catalyst agent to an external, customer-owned OTLP/HTTP endpoint to facilitate integration with existing montoring and alerting system.

These metrics include [dapr runtime metrics](https://github.com/dapr/dapr/blob/master/docs/development/dapr-metrics.md#dapr-runtime-metrics) (`dapr_*`) and catalyst metrics (`metrics_*`).

You can rename metrics and their labels before exporting them using the `transform` block, a subset of the collector's [metricstransform processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/metricstransformprocessor). Each entry selects metrics with `include` (and `match_type`) and either renames the metric via `new_name` or renames labels via `operations`. Only the `update_label` operation is supported today (assumed when `action` is omitted). Notice that `include` and `strip_labels` apply to the original metric and label names, before any transformation is applied.

Configure it under `agent.config.otel.metrics_private_export`:

```yaml
agent:
  config:
    otel:
      metrics_private_export:
        enabled: true
        # Private OTLP/HTTP metrics destination (full URL).
        endpoint: https://otlp.customer.example.com/v1/metrics
        tls_insecure: false
        # Which metrics to forward, matched per match_type.
        include:
          - dapr_runtime_workflow_execution_count
          - dapr_runtime_workflow_activity_execution_count
          - metrics_workflow_workers_connected
        # "strict" (exact names, default) or "regexp" (RE2 patterns).
        match_type: strict
        # Labels to drop before forwarding (the Diagrid export keeps all labels).
        strip_labels:
          - diagridio_org_id
        # rename metrics and/or their labels before exporting
        transform:
          # rename every catalyst metric: metrics_* -> catalyst_*
          - include: ^metrics_(.*)$
            match_type: regexp
            action: update
            new_name: catalyst_$${1}
          # rename a label on a specific metric
          - include: catalyst_conversation_tokens_total
            operations:
              - action: update_label
                label: app_id
                new_label: application_id
        # Bearer token, referenced from an existing Kubernetes Secret.
        credential_secret_name: my-otlp-token
        credential_secret_key: token
```

| Key | Description |
|-----|-------------|
| `enabled` | Turns the private export on. |
| `endpoint` | Private OTLP/HTTP metrics destination URL. |
| `tls_insecure` | Skips TLS verification for the endpoint. |
| `include` | Metrics to be forwared by name of regexp patterns depending on `match_type` |
| `match_type` | `strict` (exact names, default) or `regexp` (RE2 patterns). |
| `strip_labels` | Labels to be removed from the forwarded metrics. |
| `transform` | Rules to rename metrics (`new_name`) and/or labels (`operations`, `update_label` only). Each entry: `include`, `match_type`, `action` (`update`/`insert`), `new_name`, `operations` (`label`, `new_label`). |
| `credential_secret_name` | Name of an existing Kubernetes Secret in the collector namespace holding the bearer token. Leave empty for an endpoint that needs no auth. |
| `credential_secret_key` | Key within that Secret (default `token`). |

#### Collector addons

Catalyst includes optional OpenTelemetry Collector addons for collecting and exporting telemetry. This gives total control of the telemetry to be collected and their destination.

See the [official documentation](https://opentelemetry.io/docs/collector/configuration/) for configuration details.

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

### Management API Tunnel

Set this when the region was created with `--enable-public-management-api` (i.e. its spec has `exposeTunnel: true`). With that flag, the controlplane stands up a Piko upstream endpoint for the region; the management service in the dataplane must dial that upstream and register as its upstream so customers can reach the region's management API over the tunnel instead of via direct ingress.

```yaml
management:
  config:
    tunnel:
      enabled: true
      piko:
        upstream_url: https://tunnel-upstream.r1.diagrid.io
        audience: piko        # optional, defaults to "piko"
```

`upstream_url` is the Piko upstream of the controlplane that issued the region — the operator of that controlplane provides this value.

The management service authenticates to Piko using a JWT-SVID issued by Dapr Sentry, so the Sentry remote endpoint configured during region join must already be in place (it is, by default).

### Production Tuning

For production deployments, start from the `values-production.yaml` overlay shipped alongside this chart:

```bash
helm install catalyst ./catalyst \
  -f values-production.yaml \
  -f my-environment.yaml \
  --set join_token="${JOIN_TOKEN}"
```

The overlay enables HPAs, drops Kubernetes resource `limits` on Go components (which also drops the auto-derived `GOMEMLIMIT`), lowers log verbosity, and raises the per-project Dapr scheduler memory floor. See the [Production Tuning guide](../../guides/production/README.md) for the rationale behind each value, plus guidance on managed infrastructure (managed Kubernetes, managed PostgreSQL), PodDisruptionBudgets, securityContext hardening, and NetworkPolicies.

## Networking

Catalyst Enterprise Self-Hosted requires outbound connectivity to Diagrid Cloud. Ensure your network allows access to:

| Domain | Description | Required |
|--------|-------------|----------|
| `api.r1.diagrid.io` | Region join (installation only). | Yes |
| `catalyst-cloud.r1.diagrid.io` | Resource configuration updates. | Yes |
| `sentry.r1.diagrid.io` | Workload identity (mTLS). | Yes |
| `trust.r1.diagrid.io` | Trust anchors (mTLS). | Yes |
| `tunnels.trust.diagrid.io` | OIDC provider for Piko tunnels. | No |
| `tunnel-upstream.r1.diagrid.io` | Management API tunnel upstream (Piko). | Only if `exposeTunnel` is set on the region. |
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
