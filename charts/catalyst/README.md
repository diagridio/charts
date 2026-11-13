# Catalyst Helm Chart Reference

Configuration reference for the Catalyst Helm chart.

## Prerequisites

- Kubernetes 1.20+
- [Helm](https://helm.sh/) v3.12.0+
- [Diagrid CLI](https://docs.diagrid.io/catalyst/references/cli-reference/intro)

## Chart Dependencies

This chart includes the following dependencies:

- **OpenTelemetry Collector**: optional telemetry collection and export

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

### Overriding nested values: Helm merges maps key by key

Helm deep-merges your values file into the chart defaults per key, not per
block. Overriding one key of a nested map keeps every chart-default sibling
you did not mention. `resources` blocks are where this bites:

```yaml
# Intent: raise Envoy's memory limit. Effect: memory is raised, but cpu
# silently stays at the chart default (1000m) because it was not mentioned.
gateway:
  envoy:
    resources:
      limits:
        memory: 4096Mi
```

The result is an Envoy hard-capped at one core under load, felt as
end-to-end latency on every request while looking healthy. The same applies
to every `resources`, `nodeSelector`, `autoscaling`, and probe block in this
chart.

Rules of thumb:

- When overriding any nested block, restate **every** key you care about,
  including the ones you want at their documented default.
- To remove a chart-default key rather than override it, set it to `null`
  explicitly (this is how the production overlay drops `limits` blocks).
- After an upgrade, `helm get values --all <release>` shows the merged
  result; verify the block you overrode looks the way you intended.

Separate from Helm's values merge, some values are later consumed atomically. For
example, setting sidecar `affinity` replaces the downstream chart's default
anti-affinity outright rather than merging with it.

### Permissions (RBAC)

Catalyst is a self-managing infrastructure platform: not a static set of workloads, the Catalyst **agent** acts as an in-cluster provisioner that creates and manages a Dapr control plane, dapr sidecars, dapr CRDs, and optionally supporting infrastructure (Kafka, PostgreSQL, Redis, vcluster, sandboxes) **on demand** as you create Catalyst projects and resources. Because the exact resource set and target namespaces are decided at runtime, not at install time, the agent is granted a **cluster-scoped** role. The management and gateway components are scoped more narrowly.

Depending on your use case and installation, you may be able to remove some of the permissions provided in the default config but this must be done with caution on a case by case basis to avoid breaking functionality.

Project namespaces also enforce the Kubernetes Pod Security `baseline` standard by default; see [Pod Security for project namespaces](#pod-security-for-project-namespaces).

The Catalyst Helm chart creates 4 RBAC subjects. The tables below justify each grant so cluster operators can review the blast radius before installing.

#### 1. Agent

> 🗒️ The Catalyst Agent installs a Catalyst distribution of Dapr and thus must satisfy the permissions required by that. Many of the agent permissions are simply to align with Dapr's own RBAC permissions.

The agent's ServiceAccount (`<release>-agent-sa`, e.g. `catalyst-agent-sa`) carries the broadest permissions because it installs charts into, and reconciles resources across, many namespaces (the release namespace, the `global.namespaces` ones, per-project `prj-*`, and `default`; by default `cra-agent`, `root-dapr-system` and `shared-{kafka,postgresql,ratelimit-redis}`).

| API group | Resources | Verbs | Why it is required |
|-----------|-----------|-------|--------------------|
| `""` | `namespaces` | get, list, watch, create, patch and delete | Reconcile project namespaces. `patch` applies label changes to an existing project namespace, including the Pod Security Admission labels (see [Pod Security for project namespaces](#pod-security-for-project-namespaces)). `create`, `patch` and `delete` are granted only when the agent owns the namespace lifecycle; set `agent.config.project.externally_managed_namespaces: true` to drop them when an external owner pre-provisions namespaces (see [Externally managed namespaces](#externally-managed-namespaces)). `watch` is also needed for no-escalation against the Dapr chart. |
| `""` | `configmaps`, `secrets`, `services`, `serviceaccounts` | full CRUD | These are created by the Dapr, vcluster, OTel, Kafka, PostgreSQL, Redis, CRA sidecar, component, and namespace charts. The agent also reads image-pull secrets / infra passwords from arbitrary namespaces and syncs pull secrets into project namespaces. Cluster-wide `get`/`list`/`watch` on secrets is also required for no-escalation against `dapr-operator-admin`. |
| `""` | `pods` | get, list, watch, delete | Helm `--wait` polls pod readiness during install/upgrade (the agent never creates pods directly). `delete` is required for no-escalation against the Dapr chart. |
| `""` | `pods/log` | get | The on-error handler reads pod logs to surface install/upgrade failure details. |
| metrics.k8s.io | `pods` | get, list | *(only when `agent.config.region_usage.enabled`)* The region CPU-usage collector reads pod metrics from the cluster metrics-server for Catalyst-managed namespaces. |
| `""` | `namespaces` | patch | *(only when `agent.config.region_usage.enabled`)* Adds the `cra.diagrid.io/managed` label to the agent's own infrastructure namespaces so the collector measures them. |
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
| networking.k8s.io | `networkpolicies` | full CRUD | Per-project egress/ingress policies created by the namespace chart (see [Network Policies (Projects)](#network-policies-projects)). |
| rbac.authorization.k8s.io | `roles`, `rolebindings`, `clusterroles`, `clusterrolebindings` | full CRUD | Per-sidecar Role/RoleBinding (CRA chart) plus the ClusterRoles/Bindings installed by the Dapr chart and the OTel collectors. |
| dapr.io | `components`, `configurations`, `subscriptions`, `resiliencies`, `httpendpoints`, `mcpservers`, `workflowaccesspolicies` | full CRUD | Per-project/per-app Dapr resources rendered by the component and resource charts, plus the agent's own bootstrap Configuration. `mcpservers` and `workflowaccesspolicies` are also required for no-escalation against the Dapr chart. |
| apiextensions.k8s.io | `customresourcedefinitions` | get, create, patch | Helm creates the Dapr CRDs from the Dapr chart's `crds/` directory and the agent server-side applies any drift. `get` and `patch` cannot be limited to named CRDs because `dapr-operator-admin` grants them on every CRD (no-escalation). |
| admissionregistration.k8s.io | `mutatingwebhookconfigurations` named `dapr-sidecar-injector` | get, patch, delete | The agent installs Dapr with the sidecar injector disabled. `patch` is required for no-escalation against the `dapr-injector` ClusterRole; `get` and `delete` let Helm remove a copy left by an older release. |
| discovery.k8s.io | `endpointslices` | get | Reads the `kubernetes` service EndpointSlice in `default` to build NetworkPolicy rules that allow access to the API server. |
| agents.x-k8s.io | `sandboxes` | full CRUD | The upstream `kubernetes-sigs/agent-sandbox` CRs the gVisor sandbox provider materializes per project. |
| node.k8s.io | `runtimeclasses` | get | The gVisor sandbox provider's preflight check verifies the configured RuntimeClass is registered before creating any Sandbox. `get` only, read once at boot. |
| coordination.k8s.io | `leases` | full CRUD | Leader election for the agent itself. |

#### 2. Management Service

The management service watches resources across all project namespaces, so its role is cluster-scoped, but it is almost entirely read-only.

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

When `cleanup.enabled` is `true` (the default), `helm uninstall` runs a `post-delete` Job that tears down everything the agent provisioned at runtime: Dapr/OTel Helm releases, the Dapr namespace, and any `cra.diagrid.io/project-namespace=true` namespaces. Its RBAC objects carry `helm.sh/hook-delete-policy: hook-succeeded,hook-failed`, so they exist only for the duration of the uninstall and are then removed.

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

Set `cleanup.enabled: false` to skip this hook (and its RBAC) entirely. Note this also leaves the `region` resource intact for re-installation, as described under [Uninstall](#uninstall).

### Installing into other namespaces

Catalyst runs in the release namespace, and the agent installs the rest of the data plane into namespaces named by `global.namespaces`:

| Namespace | Holds | Set by | Default |
|-----------|-------|--------|---------|
| Release | The agent, management, the gateway, Piko, the MCP bridge and the OpenTelemetry collectors | `helm install -n <namespace>` | `cra-agent` in these docs |
| Dapr | The region's own Dapr control plane: Sentry, operator, placement and scheduler | `global.namespaces.dapr` | `root-dapr-system` |
| PostgreSQL | The shared self-hosted PostgreSQL | `global.namespaces.postgresql` | `shared-postgresql` |
| Kafka | The shared self-hosted Kafka | `global.namespaces.kafka` | `shared-kafka` |
| Redis | The managed Redis and the rate-limit service | `global.namespaces.redis` | `shared-ratelimit-redis` |
| Projects | One project's workloads | Fixed | `prj-<project-uid>` |

Any of them can be the same namespace. None of them may be a self-hosted control plane's namespace, because both install a Service named `dapr-sentry`. To run the whole data plane in one namespace, set them all to the release namespace:

```yaml
global:
  namespaces:
    dapr: catalyst
    postgresql: catalyst
    kafka: catalyst
    redis: catalyst
```

```bash
helm install catalyst oci://public.ecr.aws/diagrid/catalyst \
     -n catalyst --create-namespace \
     -f catalyst-values.yaml \
     --set join_token="${JOIN_TOKEN}"
```

Projects still get a namespace each. `global.sentry.endpoint` and `piko.publicToken.url` follow `global.namespaces.dapr` unless you set them to something other than their default. The agent, management, the sidecars, the network policies and the cleanup hook all read the same values, so nothing else needs changing.

The chart refuses to install when:

- any of the namespaces starts with `prj-`, which is reserved for projects
- any of the namespaces is the self-hosted control plane's (`global.control_plane_namespace`) or `kube-system`, or one of the `global.namespaces` values is `default`
- the release name is one the agent uses for a release it installs into the release namespace: `dapr`, `dapr-ext` or `jwt-key-rotation` when Dapr shares it, and `shared-postgresql`, `shared-kafka`, `shared-ratelimit-redis` or `shared-ratelimit-rls` when that backend does

Some things to know before you choose:

- **Upgrading needs no changes.** Every default is the name Catalyst used before, so an existing region keeps its namespaces and identities after an upgrade. The upgrade does change a few things: the agent and management configs now name the default namespaces, which restarts both; the gateway gains two identity settings and restarts; and with `networkPolicies.enabled` it adds `allow-egress-postgres`. Leave `global.namespaces` alone on an installed region.

- **Choose them once.** The release and Dapr namespaces are part of the identities of the agent, management, the gateway and Sentry, and of every project's network policies. The data backends keep their data in their namespace. Moving an installed region to other namespaces is a reinstall, and the [uninstall warning](#uninstall) applies. The agent refuses to start with a `global.namespaces.dapr` other than the one the region was installed with, rather than cut every project off from Dapr.
- **Private regions only.** Diagrid Cloud accepts a region's services from namespaces other than `cra-agent` and `root-dapr-system` only in a private region.
- **A shared namespace shares its network policies.** With `networkPolicies.enabled`, Dapr in the release namespace runs under the release namespace's policies, which allow egress to the internet but not to private ranges. Dapr in a namespace of its own has no internet egress. Projects still reach only the pods they need there: Dapr's, the data backends, management, Piko and the MCP bridge. In the other direction, a project admits Dapr's pods from Dapr's namespace and, from the release namespace, every pod except Dapr and the data backends. So keep the release namespace for Catalyst: another workload there can reach project workloads.
- **Uninstalling.** The [cleanup hook](#4-cleanup-hook-optional) deletes the Dapr namespace only when it is the default, `root-dapr-system`. A Dapr namespace you chose may have existed before Catalyst or hold other workloads, so the hook removes Dapr's releases and its trust bundle and CA from it and leaves the namespace. It never deletes the data backends.
- **A self-hosted control plane in another namespace.** The settings above are the data plane's own. If your self-hosted control plane is not in `controlplane`, set `global.control_plane_namespace` and `global.sentry.remote_namespace` to its namespace.
- **Other values that name a namespace.** `existing_secret_namespace` defaults to the release namespace. `image_pull_secret_namespace` has no default: set it to the namespace that holds the secret, usually the release namespace. Check any value you set to `cra-agent` explicitly. Pass `--agent-namespace` and `--root-dapr-namespace` to `diagrid diagnose`; the install notes print the command.
- **Deprecated keys.** `global.sentry.namespace` and `cleanup.namespaces.dapr` used to name the Dapr namespace. Left empty or at `root-dapr-system`, their old default, they follow `global.namespaces.dapr`; any other value must equal it, or the install fails.

### Externally managed namespaces

By default the agent creates every namespace Catalyst needs, and deletes a project's namespace when the project is deleted. Some clusters, often shared ones, don't let the agent create or delete namespaces. There, someone else (usually a platform team) creates them, and you tell the agent with:

```yaml
agent:
  config:
    project:
      externally_managed_namespaces: true
```

#### What changes

- The agent can only `get`, `list` and `watch` namespaces. It loses `create`, `delete` and `patch`. One exception: if `agent.config.region_usage.enabled` is `true`, the agent keeps `patch` so it can add the `cra.diagrid.io/managed` label to its infrastructure namespaces. It never gets `create` or `delete`.
- The Helm release the agent installs for each project no longer includes the project namespace. The agent puts its network policies and image-pull secret into a namespace that must already exist. It doesn't label that namespace, and doesn't delete it when the project is deleted.
- `agent.config.project.pod_security_enforce_level` does nothing, because the agent doesn't label project namespaces.

#### What stays the same

This setting only affects namespaces. Every other permission in the [agent ClusterRole](#1-agent) stays as it is, across the whole cluster: the agent still installs Dapr with its CRDs and webhooks, and still writes secrets, config maps, workloads and network policies in the namespaces below. So this setting does not keep tenants apart.

The [cleanup hook](#4-cleanup-hook-optional) runs as its own ServiceAccount, and that one can delete namespaces. On `helm uninstall` it deletes the Dapr namespace (`global.namespaces.dapr`, `root-dapr-system` by default, unless that is the release namespace) and every namespace labelled `cra.diagrid.io/project-namespace=true`, including the ones you created. If only the namespace owner should delete them, set `cleanup.enabled: false`.

#### Namespaces to create

All but the project namespaces follow your install; see [Installing into other namespaces](#installing-into-other-namespaces). The table names the defaults, and a namespace you set to the release namespace needs no creating.

| Namespace | Create it when |
|-----------|----------------|
| The release namespace, e.g. `cra-agent` | Always. `helm install --create-namespace` creates it with the installer's permissions. |
| `global.namespaces.dapr` (`root-dapr-system`) | Always. If `networkPolicies.enabled` is `true`, the chart creates it at install time with the installer's permissions. |
| `global.namespaces.postgresql` (`shared-postgresql`) | `global.postgresql.create` is `true` and `global.postgresql.disabled` is `false` (the default). |
| `global.namespaces.kafka` (`shared-kafka`) | `global.kafka.create` is `true` and `global.kafka.disabled` is `false`. |
| `global.namespaces.redis` (`shared-ratelimit-redis`) | `global.redis.create` is `true` and `global.redis.disabled` is `false`. It also holds the regional rate-limit service. |
| `prj-<project-uid>` | Once per project. |

Create the infrastructure namespaces before you install the chart. If the Dapr namespace, `shared-postgresql` or `shared-kafka` is missing, the agent stops at startup with a Forbidden error containing `cannot create resource "namespaces"`, and keeps restarting until the namespace exists. If `shared-ratelimit-redis` is missing, the agent logs a warning and runs without the managed Redis.

If `agent.config.region_usage.enabled` is `true`, label the infrastructure namespaces `cra.diagrid.io/managed: "true"` so region usage counts them. The agent adds this label itself when it has `patch`.

#### Creating a project namespace

Diagrid Cloud gives a project its UID when you create the project, so you can only create the namespace after that:

1. Create the project, for example `diagrid project create my-project`.
2. Read its UID: `diagrid project get my-project -o json | jq -r .metadata.uid`.
3. Read your organization ID: `diagrid org current` prints `<name> (<org-id>)`.
4. Create the namespace with the labels below.

The project won't become ready until the namespace exists. The agent retries every 3 minutes at first, then waits longer between tries, up to 30 minutes. Once the namespace is there, the project becomes ready on the next try, so it can take up to about half an hour. Create the namespace right after step 1 to keep that wait short.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prj-<project-uid>
  labels:
    cra.diagrid.io/project-namespace: "true"
    cra.diagrid.io/project-id: <project-uid>
    cra.diagrid.io/org-id: <org-id>
    cra.diagrid.io/project-name: my-project
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```

These are the same labels the agent sets on namespaces it creates. If one is missing:

| Label | What goes wrong without it |
|-------|----------------------------|
| `cra.diagrid.io/project-namespace` | When `networkPolicies.enabled` is `true`, the management service, Piko and the MCP bridge block traffic from the project's sidecars. Region usage doesn't count the namespace. |
| `cra.diagrid.io/project-id`, `cra.diagrid.io/org-id` | The management service can't tell which project the namespace belongs to. The project has no workflow metrics or workflow graph, LLM token use can't be charged to its budget, and region usage isn't credited to it. |
| `cra.diagrid.io/project-name` | Nothing. Nothing reads it; it just helps you find a project's namespace by name. |
| `pod-security.kubernetes.io/*` | The cluster's default Pod Security rules apply instead of `baseline`. If your workloads need a lower `enforce` level, set one; see [Pod Security for project namespaces](#pod-security-for-project-namespaces). |

#### Deleting a project

When you delete a project, the agent removes everything it put in the project namespace, but leaves the namespace itself. Delete `prj-<project-uid>` yourself once the project is gone.

#### Turning the setting on or off for an existing region

Switching the setting changes nothing for an existing project until the agent next updates that project's Helm release, which happens when something that goes into the release changes, such as its network policies. Projects created after the switch get the new behaviour straight away.

- Turning it on: each existing project namespace stays, with its labels, and becomes yours to manage. On the next update Helm takes the namespace out of the project's release and tries to delete it. The agent's ClusterRole refuses, and Helm carries on. Keep the chart's ClusterRole in place when you switch: if the agent can still delete namespaces, Helm deletes each project's namespace and everything in it.
- Turning it off: the agent can't take over a namespace your team created. Helm refuses it, and the project fails on its next update with an error containing `invalid ownership metadata`. Before you turn the setting off, give each such namespace the label `app.kubernetes.io/managed-by: Helm` and the annotations `meta.helm.sh/release-name: prj-<project-uid>` and `meta.helm.sh/release-namespace: default`. Namespaces the agent created before the setting was turned on already have them.

#### When a namespace is missing

No error mentions this setting, so look for these signs:

- Project namespace missing: the project stays not ready, and the agent logs `Apply release <release> failed: ... namespaces "prj-<project-uid>" not found`. In the `vcluster` workflow the error contains `cannot create resource "namespaces"` instead.
- Infrastructure namespace missing: the agent keeps restarting, and its last log line contains `cannot create resource "namespaces"`.

### Images

These are the images a Catalyst install with the chart's default values pulls. Use this list as a starting point for building a registry allowlist or for mirroring to a private registry.

Values that change an image, its tag or its repository change what your install pulls, so for your own install render the chart with your values file. The images the agent deploys after installation are named in the agent's ConfigMap (`config.yaml`: `sidecar`, `otel`, `internal_dapr` and `internal_dapr.sentry`). Two of them are there only when your values pin them: the Dapr control plane (`agent.config.internal_dapr.image_tag`) and the JWT key rotation job (`agent.config.internal_dapr.sentry.jwt.rotation_image`). Left empty, the agent deploys what it was built with, which the chart's `catalyst.diagrid.io/dapr-version` and `catalyst.diagrid.io/jwt-rotation-image` annotations name (`helm show chart`). The [mirror script](../../guides/air-gapped/README.md) applies that rule for you:

```bash
helm template catalyst oci://public.ecr.aws/diagrid/catalyst --version <version> \
  -f catalyst-values.yaml --set join_token=x
```

<!-- BEGIN GENERATED IMAGES: make -C charts update-catalyst-images. Do not edit by hand. -->
#### Installation Images

The chart deploys these with its default values:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Catalyst** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/catalyst-all:1.137.3` | Consolidated Catalyst services image |
| **Alpine k8s** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-hub-proxy/alpine/k8s:1.36.0` | Utility image used by Helm install and cleanup hooks |
| **Envoy Proxy** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-hub-proxy/envoyproxy/envoy:distroless-v1.38.0` | Envoy proxy for gateway |
| **Piko** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/diagrid-piko:v1.0.2` | Piko reverse tunneling service |

#### Runtime Images

The agent deploys these into the cluster after installation:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Dapr Server** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/catalyst-all:1.137.3` | Catalyst Dapr server, injected into application pods |
| **OpenTelemetry Collector** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/catalyst-all:1.137.3` | OTel collector for telemetry |
| **Dapr Sentry (Catalyst)** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/catalyst-all:1.137.3` | Catalyst Dapr certificate authority |
| **Dapr Control Plane (Catalyst)** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/dapr:1.20.0-20261112-catalyst.1` | Catalyst Dapr control plane services |
| **JWT Key Rotation** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/k8s-tools:1.0.0` | Rotates the signing keys for workload JWTs |

#### Optional Images

With `global.consolidated_image.enabled: false` the separate images replace `catalyst-all`, and `mcp.enabled: true` adds the MCP bridge:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **Dapr Server** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/sidecar:1.137.3` | Catalyst Dapr server, injected into application pods |
| **OpenTelemetry Collector** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/catalyst-otel-collector:1.137.3` | OTel collector for telemetry |
| **Dapr Sentry (Catalyst)** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/private-sentry:1.137.3` | Catalyst Dapr certificate authority |
| **Catalyst Agent** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/cra-agent:1.137.3` | Catalyst agent service |
| **Gateway Identity Injector** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/identity-injector:1.137.3` | Identity injection service |
| **Gateway Control Plane** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/catalyst-gateway:1.137.3` | Gateway control plane service |
| **Catalyst Management** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/catalyst-management:1.137.3` | Catalyst management service |
| **Catalyst MCP** | `us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/catalyst-mcp:1.137.3` | Catalyst MCP server |
<!-- END GENERATED IMAGES -->

#### Add-on Images

Used when the OpenTelemetry Collector add-ons are enabled. The tag follows the `opentelemetry-collector` chart version in `Chart.yaml`:

| Component | Default Image | Description |
|-----------|--------------|-------------|
| **OpenTelemetry Collector (OSS)** | `ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-k8s:<tag>` | Collector for traces, metrics, and logs |

### Verifying the chart and its images

This chart and the Diagrid images it installs are signed by Diagrid's release workflows, keyless, with the signatures recorded in Sigstore's public transparency log. The images also carry SLSA build provenance, a CycloneDX SBOM for each architecture and, where Diagrid has made any, OpenVEX vulnerability statements. Check the chart by digest before you install or upgrade:

```bash
version=<CHART_VERSION>
digest=$(crane digest public.ecr.aws/diagrid/catalyst:${version})

cosign verify --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/diagridio/cloudgrid/\.github/workflows/publish-catalyst-chart-release\.yaml@refs/tags/(catalyst-dataplane/)?v.+$' \
  public.ecr.aws/diagrid/catalyst@${digest}
```

and an image by the digest the chart pins:

```bash
cosign verify --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/diagridio/cloudgrid/\.github/workflows/(publish-docker-image|otel-publish-docker-image|catalyst-operator-publish-docker-image)\.yaml@refs/tags/.+/v.+$' \
  us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/sidecar@sha256:<digest>
```

The Dapr control plane image (`dapr`) is built and signed in Diagrid's Dapr repository, from `1.19.0-20261030-catalyst.2`, so it has its own identity:

```bash
cosign verify --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/diagridio/dapr-dapr/\.github/workflows/diagrid-dapr\.yaml@refs/tags/v.+$' \
  us-central1-docker.pkg.dev/prj-common-p-shared-79896/reg-p-common-docker-public/dapr@sha256:<digest>
```

Not signed: `diagrid-piko`, `k8s-tools` and Dapr builds before `1.19.0-20261030-catalyst.2`. Third-party images (Envoy, Alpine k8s, the OpenTelemetry add-ons) carry whatever their publishers attach.

[Verify Diagrid's artifacts](https://docs.diagrid.io/operate/hosting/enterprise-self-hosted/verify-artifacts) covers the rest: reading an image's SBOM and provenance, applying the VEX statements in Trivy, an admission policy that checks images as pods start, and verifying a mirror or an offline cluster.

### Private Image Registry

Point the chart at a mirrored registry:

```yaml
global:
  image:
    registry: my-registry.example.com
```

Released charts pin every Diagrid image by digest (`<registry>/<repository>@sha256:…`) and this override changes only the registry part, so the mirror has to serve the same manifests as the source registry. Copy images with a digest-preserving tool such as `crane copy` or `skopeo copy --all`. A `docker pull` followed by `docker push` can re-encode layers, and the chart then references digests the mirror does not have, which fails the pull with a manifest-unknown error.

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

The members of a [region group](https://docs.diagrid.io/operate/platform-operations/region-groups) that signs workflow history share one root here, each with its own intermediate. A region records its trust anchors on its first join, so this has to be in place before the regions join the group.

### Workload Identity Federation (JWT-SVID Audiences)

Both app sidecars and the regional **management** service mint JWT-SVIDs that identify the workload by its SPIFFE ID (`spiffe://<region-trust-domain>/ns/<project>/<app-id>` for a sidecar; `spiffe://<region-trust-domain>/ns/<release-namespace>/management` for management). In a private region these are issued by the **in-region Dapr Sentry**, and relying parties verify them against the region's OIDC discovery documents (`openid-configuration` and JWKS), which the control plane serves under a stable per-region path. By default the tokens are audience-scoped to the trust domain. To present a workload's SVID as a **federated credential** to an external identity provider, add the audience that provider expects via `global.sentry.jwt_audiences`:

```yaml
global:
  sentry:
    jwt_audiences:
      - api://AzureADTokenExchange
```

The most common use is **Microsoft Entra ID Workload Identity Federation**. Register a federated identity credential on an App Registration whose `subject` is the workload's SPIFFE ID, `audiences` is `api://AzureADTokenExchange`, and `issuer` is the region's public OIDC issuer. Read the issuer off the region rather than constructing it; it ends in an opaque per-region path segment:

```bash
diagrid region get <region-id> -o json | jq -r '.status.endpoints.oidc'
# https://oidc.r1.diagrid.io/<region-oidc-id>
```

With that audience configured here, every sidecar the agent provisions (and the regional management service) receives an SVID that can be exchanged at Azure's token endpoint for an Entra ID access token, no client secret required.

The management service uses the same mechanism when a **workflow or agent state store** references a bring-your-own secret store (for example Azure Key Vault) through a `secretKeyRef`: management resolves that secret **in-process** with its own SPIFFE identity in order to serve workflow/agent data. Federate the management SPIFFE ID (`…/ns/<release-namespace>/management`, `cra-agent` by default) on the same App Registration so it can read the store. [`setup-federated-catalyst-identity.sh`](../../guides/azure/setup-federated-catalyst-identity.sh) federates both the appid and management subjects and grants the identity the role the store needs (e.g. `Key Vault Secrets User`).

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

#### Pod Security for project namespaces

Project namespaces the agent creates carry [Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/) labels: `pod-security.kubernetes.io/enforce: baseline`, with `warn` and `audit` set to `restricted`. Every pod Catalyst runs in a project namespace meets `baseline`. Existing project namespaces pick the labels up on the agent's next reconcile.

Pod Security Admission does not evict running pods. Once a namespace enforces `baseline`, the API server rejects any new pod there that does not meet it, including a pod recreated by a rollout or a node drain. Typical examples are an injected service-mesh init container that adds the `NET_ADMIN` or `NET_RAW` capability, and a `hostPath` volume. If your project workloads need either, lower the enforce level with `agent.config.project.pod_security_enforce_level`:

| Value | Effect |
|-------|--------|
| `baseline` (default) | Enforce `baseline`. |
| `privileged` | Enforce nothing: the `privileged` level admits every pod. |
| `""` | Set no `enforce` label, so the cluster's default admission configuration applies. |

```yaml
agent:
  config:
    project:
      pod_security_enforce_level: privileged
```

Any other value fails the install. `warn` and `audit` stay at `restricted` whatever you choose, so you still see which pods would not meet it. Changing the value relabels existing project namespaces on the agent's next reconcile.

Namespaces provisioned externally (`agent.config.project.externally_managed_namespaces: true`) are not labelled by the agent, and `pod_security_enforce_level` has no effect on them; label them yourself, as shown in [Externally managed namespaces](#externally-managed-namespaces).

### Pod Scheduling

Every Catalyst workload exposes standard Kubernetes scheduling primitives (`nodeSelector`, `tolerations`, and `affinity`), so you can pin pods to specific node pools or tolerate node taints.

**One knob for everything: `shared.scheduling`**

`shared.scheduling` applies to every pod Catalyst runs or provisions:

- **Control-plane pods** the chart renders directly: agent, management, gateway.envoy, gateway.controlplane, piko.
- **Dapr sidecars** the agent provisions per app.
- **Per-project Dapr control plane** (sentry, scheduler, operator, placement) the agent provisions per project, and the JWT key-rotation CronJob beside the root Dapr control plane.
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
| mcp | `mcp.{nodeSelector,tolerations,affinity}` |
| gateway envoy | `gateway.envoy.{nodeSelector,tolerations,affinity}` |
| gateway control plane | `gateway.controlplane.{nodeSelector,tolerations,affinity}` |
| piko | `piko.{nodeSelector,tolerations,affinity}` |

Agent-provisioned per-workload overrides:

| Workload | Path |
|---|---|
| Dapr sidecars | `agent.config.sidecar.{node_selector,tolerations,affinity}` |
| Per-project Dapr control plane, JWT key-rotation CronJob | `agent.config.internal_dapr.{node_selector,tolerations,affinity}` |
| Per-project OTel collectors | `agent.config.otel.{node_selector,tolerations,affinity}` |

Example: pin everything to one pool, but also spread the gateway across nodes:

```yaml
shared:
  scheduling:
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

- **Sidecar `affinity` override replaces the default pod anti-affinity.** When `agent.config.sidecar.affinity` is unset, the cra chart spreads sidecar replicas across nodes via a built-in `podAntiAffinity`. Setting `affinity` replaces that block entirely. Include an equivalent `podAntiAffinity` in your override if you want to keep the spread.
- **Sidecar tolerations are always appended to platform-managed ones.** The free-plan spot toleration (`diagrid.dev/spot`) is appended on top of shared + per-workload tolerations when the sidecar is scheduled on spot.
- **Affinity map-merge is shallow.** If `shared.scheduling.affinity` has `nodeAffinity` and a per-workload block sets `podAntiAffinity`, both end up on the pod. If both set the same top-level key (e.g. both set `nodeAffinity`), the per-workload value replaces shared's.
- **For agent-provisioned workloads (sidecar, internal_dapr, otel), prefer `matchExpressions` over `matchLabels` inside affinity** when your label keys contain `.` (e.g. `kubernetes.io/arch`). The agent's config loader (viper) treats `.` as a path separator, so dotted keys inside `matchLabels` get split. Chart-rendered workloads (agent, management, gateway, piko) don't have this constraint.

**Shared OTel subcharts** (the optional `opentelemetry-deployment` and `opentelemetry-daemonset` subcharts at the chart root) accept the same keys and pass them through to the upstream open-telemetry Helm subchart:

```yaml
opentelemetry-deployment:
  enabled: true
  nodeSelector: { workload: catalyst }
```

See the [Kubernetes scheduling docs](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/) for the full field reference.

### Availability

Every chart-rendered workload that runs more than one replica (management by default; gateway and piko once you raise their replica counts or turn on `gateway.ha`) gets a `PodDisruptionBudget` with `minAvailable: 1` and a soft spread across nodes. Single-replica workloads render neither, so a PDB can never block a drain on a one-pod deployment.

```yaml
shared:
  availability:
    podDisruptionBudget:
      enabled: true
      minAvailable: 1
    topologySpread:
      enabled: true
      whenUnsatisfiable: ScheduleAnyway   # DoNotSchedule to insist on separate nodes
```

The gateway Envoy also serves `/ready` and `/stats/prometheus` on a pod-IP `health` port (`gateway.envoy.health`, default 9091) in front of its loopback admin API. The readiness probe on it keeps a new pod out of service until Envoy has loaded its routes.

#### Root Dapr high availability

The Dapr control plane the agent installs in `global.namespaces.dapr` runs three replicas each of operator, sentry and placement. `agent.config.internal_dapr.disable_root_dapr_ha: true` runs one of each instead, for an evaluation or development region; leave it `false` in production. The scheduler runs three replicas either way, each with a volume of `agent.config.internal_dapr.scheduler.storage_size` on the etcd backend.

#### Gateway probe

The agent asks the region's own gateway for a response on an interval, so a region with no customer traffic still produces an availability signal. It emits `cra_gateway_probe_total{result}` and `cra_gateway_probe_up` on the agent's `/metrics`.

```yaml
agent:
  config:
    gateway_probe:
      enabled: true
      interval_in_sec: 30
```

There is deliberately no `port` here: it is derived from `gateway.envoy.service.port`, so the probe cannot target a port the gateway does not serve. Set `agent.config.gateway_probe.port` to override that.

The probe is skipped, with a warning in the agent log, when `agent.config.host.ingress.service.name` is unset (see [Gateway Address](#gateway-address) for when the chart sets it) or the port is outside 1-65535. A skipped probe publishes no series at all rather than a `cra_gateway_probe_up` of 0, which would read as a gateway outage.

### Data backends (PostgreSQL, Kafka, Redis)

Catalyst relies on data backends shared across a region:

- **PostgreSQL**: backs workflows state and visualizations, AI Agents metadata, managed state components and the Dapr **scheduler** (jobs,
  reminders, cron). Catalyst defaults to automatic self-hosted deployment of PostgreSQL. It is a core part of Catalyst and all the features mentioned previously depend on the database being available. PostgreSQL is also crucial for the performance of workflows.
- **Kafka**: backs managed pub/sub. Catalyst defaults to no deployment, disallowing managed pub/sub brokers to be available on project creation.
- **Redis**: a standalone shared Redis. Disabled by default; provisioned self-hosted in-cluster or connected externally, with optional high availability. Each of the three backends is configured independently and provisioned the same way (self-hosted vs external).

#### Backwards compatibility and upgrades

Helm values for existing installations are honored to keep backwards compatibility for the configuration of the data backends.

The following helm values are **deprecated** but still supported to avoid service disruption.
- `agent.config.project.default_managed_state_store_type`
- `agent.config.project.default_managed_pubsub_type`

We advise to update helm values for existing installations to the new configuration options documented below.

> **Default behaviour change (breaking on upgrade):** Catalyst now uses a **Postgres-backed scheduler**
> by default. Previously the scheduler used an etcd backend.
> By default, on upgrade the scheduler will move from etcd to PostgreSQL.
> **There is no automatic state migration.** Existing scheduler jobs/reminders
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

   Managed offerings ship it disabled; enable their equivalent instead:

   | Provider | Setting |
   |---|---|
   | Amazon RDS / Aurora | `rds.logical_replication = 1` in the DB parameter group (reboot required) |
   | Google Cloud SQL | `cloudsql.logical_decoding = on` flag |
   | Azure Database for PostgreSQL (Flexible Server) | `wal_level = logical` server parameter (restart required) |

2. **Replication permission** for the user Catalyst connects with:

   ```sql
   ALTER ROLE <username> WITH REPLICATION;
   ```

   On Amazon RDS/Aurora the `REPLICATION` attribute cannot be granted directly;
   use the built-in role instead:

   ```sql
   GRANT rds_replication TO <username>;
   ```

#### Scheduler

The Dapr scheduler persists per-project scheduler state: scheduled jobs, actor
reminders, and workflow triggers. It supports two backends:

| `backend_type` | Where state lives | When to use |
|---|---|---|
| `postgresql` (**default**) | A PostgreSQL database | Almost all cases. Reuses the `global.postgresql` Helm value by default (`use_global: true`). |
| `etcd` | An etcd instance on a PVC | Opt out of PostgreSQL entirely (see below). |

> [!IMPORTANT]
> The PostgreSQL scheduler uses **logical replication**, so the database backing it
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
> If you disable the managed PostgreSQL, switch the scheduler to `etcd` (see below),
> otherwise rendering fails with a validation error.

**Dedicated scheduler database(s)**, *advanced*

For advanced scenarios where you want the scheduler to use a dedicated
database (or spread across multiple databases) separate from the global
PostgreSQL, set `use_global: false` and provide the connection(s) yourself. Each
entry in `connections` is one scheduler database; supply several to shard the
scheduler across databases.

Not for a member of a [region group](https://docs.diagrid.io/operate/platform-operations/region-groups), which keeps `use_global: true`. A group's safety rests on there being one replicated database with one writer, so a dedicated scheduler database adds a second replication stream and a second writer to promote; the control plane reports it as a group warning.

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
This chart version ships it as **opt-in, disabled by default** provisioned in-cluster or connected
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
| `0` (default) | `standalone`: single node, no failover. |
| `>= 1` | `replication` + **Redis Sentinel**: master + N replicas with automatic failover. |

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

To emit traces from Dapr apps into the collector (or any other OTLP backend), see the [tracing guide](../../guides/tracing/README.md); tracing is enabled per App ID via the Diagrid CLI, not through chart values.

### Secrets

Catalyst supports three secret provider backends: **Kubernetes Secrets** (default), **AWS Secrets Manager** and **PostgreSQL**.

To use AWS Secrets Manager:

```yaml
global:
  secrets:
    provider: "aws.secretmanager"
    aws:
      region: "us-east-1"
```

#### PostgreSQL Secrets Provider

The PostgreSQL secrets provider stores Catalyst application secrets in a PostgreSQL database using envelope encryption (each secret is encrypted with a data encryption key, which is itself encrypted by a key encryption key). Every member of a [region group](https://docs.diagrid.io/operate/platform-operations/region-groups) must use this provider with the same key encryption key, at the same key version: the encrypted rows replicate between members, and a member holding a different key cannot decrypt them.

How the members come to hold the same key depends on the cloud. `awskms` names one multi-region KMS key that each region resolves its own replica of, so no key material is copied anywhere — that is what the AWS guide's region group does. On Azure, `azurekeyvault` can serve a group when both regions name the same vault and key (see [Holding the KEK in Azure Key Vault](#holding-the-kek-in-azure-key-vault)); Key Vault does not replicate a key into a second region the way a multi-region KMS key does, so both regions then depend on that one vault being reachable. The alternative, and what the Azure multi-region guide does today, is `kek_provider: "local"` with the **same 64-hex `primary_encryption_key` configured in both regions**. Catalyst compares members on a fingerprint of the material rather than on the value, so two regions holding the same key report one identity and the group raises no mismatch warning. It is a weaker posture than the AWS one: the key sits in a Kubernetes secret in both clusters rather than in a managed KMS. Treat it as key material to be distributed and rotated like any other.

**Inline configuration** (connection string and keys provided directly in values):

```yaml
global:
  secrets:
    provider: postgresql
    postgresql:
      kek_provider: "local"           # "local" (AES-256), "awskms" (AWS KMS) or "azurekeyvault"
      connection_string: "postgres://user:password@host:5432/dbname"
      primary_encryption_key: "<64 hex characters>"
      primary_key_version: 1
```

##### Holding the KEK in Azure Key Vault

`kek_provider: "azurekeyvault"` wraps each data encryption key with an RSA key
held in a Key Vault, so no cluster ever holds the key material — the Azure
counterpart of `awskms`:

```yaml
global:
  secrets:
    provider: postgresql
    postgresql:
      kek_provider: "azurekeyvault"
      connection_string: "postgres://user:password@host:5432/dbname"
      azure_key_vault_url: "https://my-vault.vault.azure.net/"
      azure_key_vault_key_name: "catalyst-kek"
      # Optional: the version new DEKs are wrapped with (see Rotation below)
      azure_key_vault_key_version: ""
```

There is no credential to configure: every pod that resolves a secret — agent,
management, gateway and each project's Dapr sidecar — authenticates with the AKS
workload identity, the same way the `awskms` provider falls through to the
service account's role from IAM roles for service accounts (IRSA). That takes
four things from you, none of which this chart can do on its own:

1. Workload identity enabled on the AKS cluster (`az aks update
   --enable-oidc-issuer --enable-workload-identity`).
2. The identity granted **Key Vault Crypto User** on the key — wrapping keys
   is a different role from reading secrets, so `Key Vault Secrets User` alone
   is not enough. The guide scripts under `charts/guides/azure/` grant both when
   passed `--keyvault`, scoped to the **whole vault**: the identity can then wrap
   and unwrap with every key in it, not only the KEK. To hold it to the one key,
   assign the role on the key instead (`--scope <vault resource id>/keys/<key
   name>`), or give the KEK a vault of its own.
3. The pods pointed at that identity, via this chart's existing `podLabels` and
   `serviceAccount.annotations`. `global.serviceAccount.annotations` reaches the
   agent and management service accounts; the gateway's control-plane service
   account has its own:

   ```yaml
   global:
     serviceAccount:
       annotations:
         azure.workload.identity/client-id: "<the identity's client id>"
   agent:
     podLabels:
       azure.workload.identity/use: "true"
   management:
     podLabels:
       azure.workload.identity/use: "true"
   gateway:
     controlplane:
       podLabels:
         azure.workload.identity/use: "true"
       serviceAccount:
         annotations:
           azure.workload.identity/client-id: "<the identity's client id>"
   ```

   Each of those three service accounts also needs a federated credential on
   the identity, with subject `system:serviceaccount:<namespace>:<name>` and
   audience `api://AzureADTokenExchange`.
4. The **sidecars** pointed at it too. Every project's Dapr sidecar builds its
   own KEK provider from the component metadata the agent publishes, so it
   unwraps DEKs itself and needs the same identity. Each sidecar runs under a
   service account of its own, `sidecar-<project-uid>-<appid-uid>` in the
   `prj-<project-uid>` namespace, so the identity needs one more federated
   credential for every app, created when the app is. The sidecar pods are
   provisioned by the agent, not by this chart's templates, so they are labelled
   through the agent's own region-wide sidecar settings — miss this and app
   secret reads fail with an Azure credential error while the control plane looks
   healthy:

   ```yaml
   agent:
     config:
       sidecar:
         pod_labels:
           - key: azure.workload.identity/use
             value: "true"
         service_account_annotations:
           - key: azure.workload.identity/client-id
             value: "<the identity's client id>"
   ```

**Twenty federated credentials per identity.** Azure caps a managed identity at
[20 federated credentials](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-considerations),
and none of them can be a wildcard. One identity shared as above holds three for
the agent, management and gateway plus one per app, so it runs out at 17 apps in
the region.

**One identity per app.** Past that, or to keep one app's identity away from
another app's Azure resources, give each app its own identity, as the
[Azure installation guide](https://docs.diagrid.io/operate/hosting/enterprise-self-hosted/azure-installation-guide#managed-identities)
does. [`setup-user-managed-catalyst-identity.sh`](../../guides/azure/setup-user-managed-catalyst-identity.sh)
`--project <project> --app <app>` creates the identity and the app's one
federated credential, then prints the `diagrid appid update --label
azure.workload.identity/use=true --annotation
azure.workload.identity/client-id=<client id>` that points the app at it. An
app's own annotation overrides the region-wide `service_account_annotations`
default from point 4, so that app's sidecar unwraps DEKs as the app's identity.
That identity therefore needs **Key Vault Crypto User** on the KEK as well as
the roles the app itself uses. `--keyvault <vault>` grants it, together with
`Key Vault Secrets User`, vault-wide as in point 2. If the KEK has a vault of its
own, run the script again with that vault: it reuses the identity and
credential it already created. The shared identity then needs only the control
plane's three credentials. Keep the point 4 default, and a credential on the
shared identity for each app still using it, until every app has an identity of
its own: an app with no annotation falls back to the default.

**Rotation.** Rotate the key in the vault as usual — manually or with a rotation
policy. Every wrapped DEK records the key version that wrapped it and is always
unwrapped with that version, so rows written before a rotation stay readable.
`azure_key_vault_key_version` only chooses the version **new** DEKs are wrapped
with: leave it empty to follow the key's current version, or set it to hold new
wraps on one version. Either way, keep every version that still wraps a row
enabled in the vault — disabling or purging an old version makes its rows
unreadable, and existing rows are not re-wrapped onto the new version.

**Region groups.** Both members of a region group must name the same vault and
key, spelled the same way — see RFC 0003 premise 4 for why, and for what the
control plane does when they disagree. The key version is not part of that
comparison: each row names its own, so members may wrap new DEKs with different
versions of the one key.

**Using an existing Kubernetes secret** (recommended for production, since it keeps all sensitive config out of values files):

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

>NOTE: When `existingSecret` is set, **all** PostgreSQL secrets provider config is read from the referenced Kubernetes secret via environment variables. Nothing is written to the ConfigMap. All keys are read with `optional: true`, so keys that are absent from the secret are simply not set and the application uses its built-in defaults (useful for optional fields like secondary keys, or AWS KMS / Azure Key Vault config). By default the secret key names match the config field names. Override individual key names using `existingSecretKeys` if your secret uses different naming:

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

### Catalyst Assistant model credential

The Catalyst Assistant answers questions about the workflows and App IDs in this
region, which means it calls a model provider. That provider credential lives in
this region and nowhere else. Diagrid's control plane names it but never holds it,
so a region you own runs the assistant on a key Diagrid never sees.

Leaving this unset is a normal installation: a region that runs no assistant, or one
whose model provider needs no credential, needs nothing here.

Prefer `existingSecret`, so the key never passes through a values file that may be
committed, templated or copied around:

```yaml
agent:
  reagent:
    llm:
      existingSecret:
        name: "my-model-key"
        key: "api_key"
```

`apiKey` is the alternative, convenient for a local or throwaway install. It puts
the credential in the chart's values, which Helm also stores verbatim in the
release history:

```yaml
agent:
  reagent:
    llm:
      apiKey: "sk-..."
```

`existingSecret` takes precedence when both are set. The Secret must live in the
release namespace. Only its name and key reach the agent's ConfigMap; the material
is read at reconcile time and copied into the assistant's own project namespace,
which is the only place the assistant's model component will resolve it from.

To rotate, replace the Secret. Nothing needs to be reinstalled and no pod needs to
be restarted: the agent re-applies the copy in the assistant's project namespace on
the next reconcile of that project, and the running assistant then picks the new
credential up on its own.

Rotation is therefore **eventual, not immediate**. Allow up to the agent's
drift-reconcile interval (15 minutes by default) for the copy to be re-applied,
plus a few seconds for the assistant to observe it. If you are rotating in response
to a suspected disclosure and want the old credential out of use at once, restart
the assistant's workload rather than waiting:

```bash
kubectl rollout restart deployment -n <the assistant's project namespace> -l dapr.io/app-id=reagent
```

### Enterprise Identity (dp Sentry IdP Federation + OBO)

Catalyst can propagate the invoking user's identity from an upstream IdP through to downstream MCP calls via on-behalf-of (OBO) tokens minted by dp Sentry. The three values that govern this live under `agent.config.internal_dapr.sentry.oidc`:

| Path | Type | Default | Purpose |
|---|---|---|---|
| `agent.config.internal_dapr.sentry.oidc.idp_federation_enabled` | boolean | `false` | Whether dp Sentry validates inbound user JWTs against `IDPFederation` resources. |
| `agent.config.internal_dapr.sentry.oidc.bootstrap_issuers` | array of strings | `[]` | Issuers dp Sentry pre-warms JWKS for on startup. Each entry must exactly match an `IDPFederation`'s `iss` (e.g. `https://<tenant>.auth0.com/`). Empty means no pre-warm; federations still work but the first request per issuer pays a cold-fetch. |
| `agent.config.internal_dapr.sentry.oidc.mtls.enabled` | boolean | `false` | Whether dp Sentry serves its SPIFFE-mTLS `/token` listener. Sidecars reach the identity-assertion and OBO delegation grants over this listener. |

**Activation rule (enforced by the JSON schema):** `idp_federation_enabled` and `mtls.enabled` must move together. Enabling federation without the mTLS listener leaves policied MCP calls failing closed at `503 oauth.verifier_unavailable`; enabling the listener without federation advertises an endpoint no federation resolves against. `helm install` / `helm upgrade` rejects the mismatch.

**When to enable:**
- Only in environments that federate at least one IdP tenant. For onebox and cloud envs where Diagrid ships a bootstrap federation via ConfigMap (`catalyst-idp-federation-*`), the values are pre-set; overlays should not override them.
- BYOC / self-hosted operators enable both flags together after creating their first `IDPFederation` resource via `diagrid idp create`.

**What breaks with a partial config:**
- `idp_federation_enabled: true` + `mtls.enabled: false` → inbound sidecar middleware validates the user token but cannot reach the delegation grant → outbound OBO mint fails closed at 503.
- `idp_federation_enabled: false` + `mtls.enabled: true` → dp Sentry advertises the mTLS listener but has no federation to validate against → tokens are rejected as untrusted.


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

Catalyst Enterprise Self-Hosted requires outbound connectivity to Diagrid Cloud.

| Endpoint | mTLS | Client | Purpose | Required |
|---|---|---|---|---|
| `catalyst-cloud.r1.diagrid.io:443` | Yes | agent, management, gateway-controlplane, project sidecars | Resource and configuration sync, events | Yes |
| `sentry.r1.diagrid.io:443` | Yes | agent, project sidecars, in-region Sentry | Workload identity (SVID issuance) | Yes |
| `trust.r1.diagrid.io` | No | agent, management, gateway-controlplane, sidecars, in-region Sentry | Fetches the Diagrid trust anchors at startup. A workload that cannot verify it does not start. | Yes |
| `api.r1.diagrid.io` | No | agent, management | Control plane HTTPS API | Yes |
| `public.ecr.aws` | No | agent | Pulls the internal Dapr chart at runtime | Yes |
| `us-central1-docker.pkg.dev` | No | agent, container runtime | Container images | Yes |
| `login.diagrid.io` | No | management | IdP JWKS, to validate user tokens | Yes |
| `catalyst-metrics.r1.diagrid.io` | No | metrics collector | Dapr runtime metrics | No |
| `catalyst-logs.r1.diagrid.io` | No | logs collector | Dapr sidecar logs | No |
| `tunnel-upstream.r1.diagrid.io` | No | management | Management API tunnel upstream, Piko | Only when `exposeTunnel` is set on the region |

Container image pulls are performed by the container runtime, not by this chart,
so a proxy in front of the registry needs its CA in the nodes' trust store.

### Proxying Outbound Connections

It is possible to route the outbound connections via a firewall or proxy. You will only be able to terminate TLS for the non-mTLS connections from the table above. The mTLS connections must pass through your firewall or proxy without content inspection.

To proxy the TLS connections, you need to configure Catalyst to trust the CA that your firewall or proxy uses to terminate TLS. You can do this by setting `global.trustedCA` in your Helm values.

To provide a trusted CA, set exactly one of the following two sources.

1. **Reference an existing ConfigMap (Recommended)**:

```yaml
global:
  trustedCA:
    existingConfigMap:
      name: corporate-dpi-ca
      # Optional; defaults to "ca.crt".
      key: ca.crt
```

2. **Inline PEM**:

```yaml
global:
  trustedCA:
    certs: |
      -----BEGIN CERTIFICATE-----
      ...
      -----END CERTIFICATE-----
```

If you choose to use the `existingConfigMap` source, you must roll out the following workloads after you've updated the ConfigMap to ensure that the new CA is picked up:

```sh
kubectl -n <release-namespace> rollout restart deploy/agent deploy/management \
  deploy/catalyst-mcp deploy/catalyst-gateway-controlplane
```

#### Disabling TLS Verification

You should never disable TLS verification in production. If you need to trust a self-signed certificate for your proxy or firewall, use the `global.trustedCA` option above.

If you do need to disable TLS verification for testing or troubleshooting, you can set `global.tls.insecureSkipVerify: true` in your Helm values. This will turn off certificate verification for every outbound connection this chart configures to a Diagrid endpoint.

```yaml
global:
  tls:
    insecureSkipVerify: true
```

### Sidecar Outbound TLS Trust

the setting `global.trustedCA` documented above already reaches every sidecar; this section is for CAs that **only** the
sidecars need and you do not want to load into other services. To let the Catalyst sidecars trust upstreams they connect *out* to (MCP servers, external HTTP endpoints, service invocation, bindings) that terminate TLS with a **private or self-signed CA**, add the CA to the sidecars' trust via `agent.config.sidecar`. The trust applies region-wide to every sidecar the agent provisions.

To provide a sidecar trusted CA, set exactly one of the following two sources.

1. **Reference an existing ConfigMap (recommended)**:

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

2. **Inline PEM**:

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

Leave both sources empty to trust only public roots (the default). This setting
composes with `global.trustedCA`: sidecars trust the union of the two.

### Gateway TLS

The Catalyst gateway is responsible for ingress traffic into the region, on the region's wildcard domain (`*.<region-domain>`). It routes on the hostname in the TLS handshake (SNI), and handles two kinds of traffic differently:

- **Terminated at the gateway**, with the certificate below: your projects' endpoints and the region's HTTP services (`oidc.`, `tunnels.`, `tunnels-proxy.` and `management.<region-domain>`).
- **Passed through unchanged** to the region's gRPC control plane services, which present their own certificates. The gateway never decrypts these:

  | Hostname | Service in the region |
  |---|---|
  | `sentry.<region-domain>` | Dapr Sentry (`dapr-sentry`) |
  | `xrs.<region-domain>` | Management (`management`) |
  | `dapr-api.<region-domain>` | Dapr operator API (`dapr-api`) |
  | `dapr-placement.<region-domain>` | Dapr placement (`dapr-placement-server`) |
  | `dapr-scheduler.<region-domain>` | Dapr scheduler (`dapr-scheduler-server`) |
  | `dapr-scheduler-server-<N>.<region-domain>` | One per scheduler replica, `0` to `2` by default |

So anything in front of the gateway, such as a cloud load balancer or your own, must forward TCP without terminating TLS or rejecting HTTP/2. An L7 proxy or WAF there breaks the passthrough hostnames. The [Gateway Exposure guide](../../guides/gateway-exposure/README.md#layer-4-only) lists what works and what breaks it on each cloud.

You can provide your own TLS certificate and key for the gateway via the following Helm values. The certificate and key can be provided inline or via an existing Kubernetes secret.

```yaml
gateway:
  tls:
    enabled: true
    existingSecret: "my-tls-secret"
    # Or provide cert/key inline
```

With `gateway.plaintextRedirect: true`, when the region's ingress is https and the gateway holds a certificate, the plaintext port (`gateway.envoy.service.port`, 8080 by default) answers every plain-HTTP request with a 308 redirect to https, and https responses carry `Strict-Transport-Security`. The one exception is the region-group health route, which stays reachable in plaintext; TLS passthrough to the Dapr control plane services on that port is unchanged, and a blocked region keeps answering 403 on both ports. A region whose ingress is http keeps serving all its routes on the plaintext port. Leave it off (the default) when a proxy in front of the gateway terminates TLS and forwards plain HTTP to that port, or every request is redirected back to that proxy.

`gateway.corsAllowedOrigins` lists the Catalyst console origins whose browser requests the region's project endpoints accept (CORS). Leave it empty for the Diagrid-hosted consoles, the default. A self-hosted control plane sets its own console, for example `["https://catalyst.example.com"]`.

For step-by-step instructions covering self-signed (dev), bring-your-own certificates, cert-manager integration, a [private or self-signed CA](../../guides/gateway-tls/README.md#private-or-self-signed-ca), and rotation, see the [Gateway TLS guide](../../guides/gateway-tls/README.md).

### Gateway Address

The agent reports the region's ingress address to the controlplane. When the gateway is exposed as a LoadBalancer, the agent reads that address from the gateway Service and follows it if the load balancer is rebuilt. You do not need to name the Service:

```yaml
gateway:
  envoy:
    service:
      type: LoadBalancer
```

With that set and `agent.config.host.ingress.ip_addr` empty, the chart points the agent at `gateway.envoy.service.name` in the release namespace. Set `agent.config.host.ingress.service.name` and `.namespace` only when the ingress is a different Service, or `ip_addr` when it has a static address. A `ClusterIP` or `NodePort` gateway gets no default, because it never receives a LoadBalancer address and the agent would exit waiting for one.

The agent also reports the Service's `https` port (`gateway.envoy.service.httpsPort`, `8443` by default), or `agent.config.host.ingress.port` (`443` by default) when `ip_addr` is set. The region's `--ingress` must use the same port. For a public or private address, a fixed address, `NodePort` behind your own load balancer, the port and DNS, see the [Gateway Exposure guide](../../guides/gateway-exposure/README.md).

### Managed Domain

> **Note:** Managed Domain requires Diagrid Cloud. A control plane you run yourself neither creates the DNS record nor issues a publicly trusted certificate, so bring your own domain and certificate there; see [Gateway TLS](#gateway-tls).

Set this when you want Diagrid Cloud to allocate the region's public wildcard hostname and TLS certificate for you, instead of bringing your own. Your `--ingress` endpoint then only needs to resolve **locally** (or privately) to the gateway. The controlplane allocates a public wildcard subdomain (under `privatediagrid.net` for Diagrid Cloud) and a matching wildcard certificate, then delivers them to the dataplane.

Use this if you do not want to own a public wildcard DNS zone for the region, or provision and rotate a wildcard TLS certificate for the gateway.

Enable it at region creation time:

```bash
diagrid region create <region-id> --enable-managed-domain --ingress <local-endpoint>
```

With managed domain, `--ingress` is a locally resolvable address (e.g. an internal hostname or an IP). Without it, `--ingress` must be a wildcard FQDN that you control (e.g. `*.my-region.company.com`), resolvable from every network that has to reach the region; see [DNS](../../guides/gateway-exposure/README.md#dns) in the Gateway Exposure guide.

When managed domain is enabled, you can omit the `gateway.tls` block from your Helm values; the certificate is provisioned by the controlplane and delivered to the dataplane gateway. See [Gateway TLS](#gateway-tls) for the bring-your-own case.

> **Note:** managed domains add a runtime dependency on the controlplane's DNS and certificate-issuance infrastructure. If you require strict isolation from external services, stick with a bring-your-own domain and certificate.

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

`upstream_url` is the Piko upstream of the controlplane that issued the region; the operator of that controlplane provides this value.

The management service authenticates to Piko using a JWT-SVID issued by Dapr Sentry, so the Sentry remote endpoint configured during region join must already be in place (it is, by default).

### Network Policies (System)

Catalyst always generates NetworkPolicies for **project namespaces** (deny-all plus explicit allows, created by the agent at provisioning time). The **system namespaces** (the release namespace and the internal Dapr namespace) ship without policies by default. On clusters with a default-deny security mandate, enable the chart-managed set:

```yaml
networkPolicies:
  enabled: true
```

This installs deny-all policies for both system namespaces plus the explicit allows Catalyst needs: intra-namespace traffic, project-sidecar access to piko/management and the Dapr control plane, public ingress to the gateway, and egress to DNS, the Kubernetes API server, the Diagrid control plane (public internet except private ranges, since standard NetworkPolicy cannot match hostnames), and project namespaces.

These policies only take effect on clusters whose CNI enforces NetworkPolicy (Calico, Cilium, Azure NPM, ...). Without one they are silently inert; the agent logs a warning at startup when no enforcing CNI is detected.

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
  # Allows agent egress to an in-cluster PostgreSQL of your own on 5432
  # (scheduler and managed state store databases). Leave it unset for the
  # PostgreSQL the chart creates: the allow follows global.namespaces.postgresql.
  postgres:
    namespace: "postgres"
  # Extra egress allows for private destinations (VNet databases, private
  # endpoints) that the internet-egress policy's private-range excepts block.
  extraEgress:
    - cidr: 10.100.0.0/24
      ports:
        - port: 5432
```

The PostgreSQL and Kafka the chart creates (`global.postgresql.create`, `global.kafka.create`) get their agent egress allows automatically, to `global.namespaces.postgresql` on 5432 and `global.namespaces.kafka` on 9092.

If the PostgreSQL namespace is itself default-deny, its ingress allows are yours to manage: both the release namespace (agent) and every project namespace (sidecars connect directly for managed state stores) need ingress on 5432.

### Network Policies (Projects)

Catalyst configures Kubernetes `NetworkPolicy` resources per project namespace using three symmetric lists:

| Key | What it does |
|-----|--------------|
| `agent.config.project.blocked_egress`  | Denies destinations in the sidecar `0.0.0.0/0` egress rule. CIDR-only (NetworkPolicy `except` limitation). |
| `agent.config.project.allowed_egress`  | Additive egress allow rules. May target CIDRs and/or namespaces, with optional port scoping. |
| `agent.config.project.allowed_ingress` | Additive ingress allow rules into project namespaces. May target CIDRs and/or namespaces, with optional port scoping. |

**Precedence: allow beats block.** NetworkPolicy rules are additive (the API server OR's them together), so any
destination matched by an `allowed_egress` entry is reachable even if its CIDR also appears in `blocked_egress`. Use
this to punch narrow holes through the block list rather than weakening it.

**Ingress floor (non-configurable):** the release namespace (`cra-agent` by default) and the `monitoring` namespace are always
permitted as ingress sources. Management and Prometheus scraping therefore never break regardless of `allowed_ingress`.

#### What each project namespace gets

The agent writes these policies into every project namespace, each named after it (`deny-all-prj-<N>` and so on).
"Project pods" means every pod in the namespace except agent sandbox pods (label `cra.diagrid.io/sandbox-netpol`),
which get a narrower policy of their own.

| Policy | Selects | Allows |
|---|---|---|
| `deny-all-` | every pod | Nothing. Denies all ingress and egress, so only what the policies below allow gets through. |
| `allow-internal-` | project pods | Ingress from and egress to every pod in the same namespace. |
| `allow-egress-` | project pods | Egress to `0.0.0.0/0` except the `blocked_egress` CIDRs. DNS on port 53, TCP and UDP, to pods labelled `k8s-app: kube-dns` in `kube-system` and to the ClusterIP of the `kube-system/kube-dns` Service. One rule per `allowed_egress` entry. The Kubernetes API server, only with the Kubernetes secrets provider. |
| `allow-system-ingress-` | project pods | Ingress from the release namespace and `monitoring`, plus one rule per `allowed_ingress` entry. |
| `allow-egress-management-` | project pods | Egress to the management pods in the release namespace. |
| `allow-egress-piko-` | project pods | Egress to the Piko pods in the release namespace. |
| `allow-dapr-root-access-` | project pods, on projects that use the shared Dapr control plane | Egress to the Dapr control plane in `global.namespaces.dapr`, and ingress from that namespace. |
| `allow-dapr-cp-egress-` | pods labelled `app.kubernetes.io/name: dapr` | Egress to the Kubernetes API server, for a project that runs its own Dapr control plane. |
| `allow-egress-shared-postgresql-`, `allow-egress-postgresql-secrets-`, `allow-egress-shared-kafka-`, `allow-egress-shared-redis-` | project pods, when that backend is in use | Egress to that backend's namespace or subnets. |

Any other namespace, including the one your ingress controller runs in, needs an `allowed_egress` entry with
`namespaces`.

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

How each field becomes a policy peer:

- **`cidrs`** become `ipBlock` peers. The Kubernetes documentation says `ipBlock` is meant for
  [cluster-external IPs](https://kubernetes.io/docs/concepts/services-networking/network-policies/#behavior-of-to-and-from-selectors),
  and that whether a rewritten destination is matched before or after the rewrite depends on the network plugin. Do not
  rely on a CIDR, including the `0.0.0.0/0` of `allow-egress-`, to reach pods.
- **`namespaces`** become a `namespaceSelector` on `kubernetes.io/metadata.name`, with no pod selector: the rule allows
  every pod in those namespaces. `allowed_egress` cannot pick pods within a namespace. To allow only some pods, scope
  the rule with `ports`, or add a NetworkPolicy of your own to each project namespace. Policies add up and the agent does
  not remove one it did not create, but you must add yours to each new project.
- **`ports`** match the port the packet is addressed to when the policy sees it. For a pod reached through a Service,
  that is the pod's port (the Service's `targetPort`), not the Service port.

A hostname that resolves to a `LoadBalancer` Service in the same cluster is the case these rules catch out. kube-proxy,
and network plugins that replace it, usually deliver traffic for the load balancer's IP straight to the Service's pods
without it leaving the cluster. The policy then sees a pod as the destination, so allow it with `namespaces` and the
pods' ports rather than with the load balancer's IP.

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
> CNI, or kube-router). On EKS, enable it on the AWS VPC CNI with the `vpc-cni` add-on setting
> `enableNetworkPolicy: "true"`; on a self-managed install, set `ENABLE_NETWORK_POLICY=true` on the `aws-node`
> DaemonSet. If none is detected at startup the agent logs a warning and policies are still created although not
> enforced.

## Documentation

- [Catalyst Documentation](https://docs.diagrid.io/catalyst)
- [Catalyst Support](https://docs.diagrid.io/catalyst/support)
- [Diagrid Website](https://www.diagrid.io/)
- [Diagrid Support](https://diagrid.io/support)
