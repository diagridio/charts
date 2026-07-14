# Production Tuning

Guidance for self-hosted Catalyst deployments handling real traffic. Pair this
with the tracked overlay
[`values-production.yaml`](../../charts/catalyst/values-production.yaml):

```bash
helm install catalyst ./catalyst \
  -f values-production.yaml \
  -f my-environment.yaml \
  --set join_token="${JOIN_TOKEN}"
```

The defaults in [`values.yaml`](../../charts/catalyst/values.yaml) are
deliberately conservative for evaluation. The recommendations below are the
starting point we suggest for production deployments before tuning further
for your workload.

## At a glance

| Component | Default | Production overlay | Why |
|-----------|---------|--------------------|-----|
| `agent.logLevel` | `info` | `error` | Cut log volume |
| `agent.resources.limits` | `memory: 1200Mi` | dropped | Avoid OOMKill / GC throttling |
| `agent.config.sidecar.log_level` | unset | `error` | Cut sidecar log volume |
| `agent.config.sidecar.autoscaling.enabled` | `false` | `true` (min 2 / max 10) | Real traffic needs headroom |
| `agent.config.sidecar.resources.limits` | `cpu: 1, memory: 512Mi` | dropped | Same as agent |
| `agent.config.internal_dapr.scheduler_resources.limits` | `memory: 175Mi` | dropped | OOMKill under job fanout |
| `management.logLevel` | `info` | `error` | Cut log volume |
| `management.autoscaling.enabled` | `false` | `true` | Match real load |
| `management.resources.limits` | `memory: 1200Mi` | dropped | Same as agent |
| `gateway.envoy.autoscaling` | `1–5 / 80%` | `3–10 / 70%` | Data-plane hot path |

## Managed infrastructure

The recommended path for production is to run Catalyst on managed
infrastructure rather than self-hosting the supporting services in-cluster.
The cloud providers' managed offerings give you backups, point-in-time
recovery, HA, and security patching out of the box — none of which the
in-cluster shortcuts in our examples provide.

- **Managed Kubernetes** — EKS, GKE, or AKS. The chart's
  [Cluster Requirements](../../charts/catalyst/README.md#cluster-requirements)
  section lists prerequisites; any current managed offering meets them.
- **Managed PostgreSQL** — Amazon RDS, Cloud SQL, or Azure Database for
  PostgreSQL. Catalyst uses PostgreSQL for the state store, the Dapr scheduler,
  and workflow state. The overlay already defaults the chart to external
  PostgreSQL (`global.postgresql.create: false`,
  `global.postgresql.external.auth_type: connectionString`) — you only need to
  supply the connection details from your environment values. The Postgres-backed
  scheduler (the chart default) reuses this same external Postgres.

  > [!IMPORTANT]
  > The Postgres-backed scheduler uses PostgreSQL **logical replication**, so the
  > external database must be configured with `wal_level = logical`. Managed offerings
  > ship this **disabled** by default — enable it before deploying, or the
  > `dapr-scheduler-server` pods crash with `logical decoding requires "wal_level" >= "logical"`:
  > - **Amazon RDS / Aurora** — set `rds.logical_replication = 1` in a custom DB
  >   parameter/cluster-parameter group and reboot the instance.
  > - **Cloud SQL** — set the `cloudsql.logical_decoding` flag to `on` (restarts the instance).
  > - **Azure Database for PostgreSQL (Flexible Server)** — set the `wal_level` server
  >   parameter to `logical` (restarts the server).
  >
  > If you instead point the scheduler at a **dedicated** database
  > (`agent.config.internal_dapr.scheduler.postgresql.use_global: false`), enable
  > `wal_level = logical` on that database rather than the state-store one. Only the
  > scheduler's database needs logical replication; the state store does not.

  Use a Kubernetes secret rather than inline plaintext credentials. Create
  a secret with keys `host`, `port`, `username`, `password` (and optionally
  `proxy_host`), then reference it:

  ```yaml
  global:
    postgresql:
      external:
        existing_secret_name: catalyst-postgres
        existing_secret_namespace: catalyst
  ```

  AWS Aurora users can switch `global.postgresql.external.auth_type: awsiam` and
  configure `aws_auth.*` instead of password-based credentials.

  Running PostgreSQL inside the same cluster as Catalyst is fine for
  evaluation but is not a posture we recommend for production. See the
  **Workflows** section of the
  [chart README](../../charts/catalyst/README.md) for the full schema.
- **Managed object storage / Kafka / Redis** — when used as Dapr
  components, prefer the cloud-managed offerings over self-hosted
  StatefulSets.

The values overlay is agnostic to which managed offering you pick; the
hosts, credentials, and TLS settings belong in your own per-environment
values file alongside `values-production.yaml`.

## Why drop Kubernetes `limits`

For Go services, Kubernetes resource `limits` interact badly with the GC under
production load:

- A **memory `limit`** that's reached triggers OOMKill, dropping the pod
  mid-request. Go's GC will free memory eventually, but cgroup enforcement is
  immediate. Under bursty load the OOMKill window arrives before GC does.
- A **CPU `limit`** that throttles a Go process slows the GC itself, which
  *increases* memory pressure, which makes the OOMKill more likely. The two
  knobs combine into a feedback loop.
- `requests` are still set, so the scheduler places pods on nodes that can
  fit them. Dropping `limits` only removes the cgroup ceiling.

The chart auto-derives `GOMEMLIMIT` from `*.resources.limits` (see
[`templates/_helpers.tpl`](../../charts/catalyst/templates/_helpers.tpl) ::
`catalyst.GetGoLangGOMEMLIMITFromResourceLimits`). When you drop `limits`,
`GOMEMLIMIT` is no longer emitted — that's intentional. If you want a soft
GC ceiling without a hard cgroup limit, set `*.goSoftLimit.override` to an
explicit byte value.

This applies to every Go component: `agent`, `management`, the per-AppID
sidecar, and the per-project Dapr scheduler.

## Sidecar autoscaling

The chart's defaults:

- `replicas: 1`
- `autoscaling.enabled: false`

That's fine for evaluation. For production:

- **`min_replicas: 2`** — keeps capacity headroom across rolling updates and
  voluntary node drains. A single replica means a one-pod restart drops 100%
  of capacity.
- **`max_replicas: 10`** — generous headroom; HPA only scales up if CPU
  exceeds the target. Raise for high-throughput apps.
- **`target_cpu_utilization_percentage: 80`** — leaves CPU headroom for
  bursts without flapping. Lower (60–70%) for stricter latency SLOs.

A min=max configuration disables HPA in practice (the controller has nowhere
to scale to). If you need a fixed pod count for a specific app, leave
`autoscaling.enabled: false` and set `replicas` directly — but understand
that's a non-production posture.

## Dapr scheduler

The per-project Dapr scheduler manages reminder/job state. Its memory grows
with the number of pending jobs, so the chart's default ceiling
(`scheduler_resources.limits.memory: 175Mi`) becomes the binding constraint
under load — when crossed, the pod is OOMKilled and the entire project's
scheduling pipeline restarts.

The overlay drops the limit and bumps the request to `256Mi`.

## Log verbosity

Production deployments should run with `error`-level logs:

- `agent.logLevel: error` — agent itself.
- `management.logLevel: error` — management service.
- `agent.config.sidecar.log_level: error` — per-AppID sidecars.

The volume difference vs `info` is large enough to dominate cluster logging
costs at scale. Bump back to `info` or `debug` via `helm upgrade` when
investigating incidents — log level is not a runtime knob, so plan for the
restart that comes with the upgrade.

## Gateway / Envoy

Envoy sits on the data-plane hot path; under-provisioned Envoy is felt as
end-to-end latency on every request through Catalyst. Defaults
(`minReplicas: 1, maxReplicas: 5, target: 80%`) are fine for evaluation.

For production, the overlay sets `3–10 replicas` with a `70%` CPU target —
three replicas tolerate a node failure without dropping below two; lowering
the CPU target to 70% trades a little headroom for tighter p99 latency.

## PodDisruptionBudgets

The chart does not ship `PodDisruptionBudget` resources for the control-plane
components. For production, define a PDB for each component the overlay puts
behind an HPA so that voluntary node drains (cluster upgrades, autoscaler
events) cannot reduce capacity below a safe threshold.

Example — apply alongside the chart in the same release namespace:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: catalyst-management
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: catalyst
      app.kubernetes.io/component: management
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: catalyst-gateway-envoy
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: catalyst
      app.kubernetes.io/component: gateway-envoy
```

Use `minAvailable` rather than `maxUnavailable` so the PDB stays correct as
the HPA scales the workload up. Pick a value below the HPA's `minReplicas`
(e.g. `minReplicas: 3` → `minAvailable: 2`) so a single pod can always be
evicted.

The agent itself runs as a single replica today, so a PDB is not useful for
it — drains will recreate it on a new node.

## securityContext hardening

The chart already sets sensible pod- and container-level defaults on every
control-plane component (see [`values.yaml`](../../charts/catalyst/values.yaml)):

- `runAsNonRoot: true`
- `seccompProfile.type: RuntimeDefault`
- `allowPrivilegeEscalation: false`
- `capabilities.drop: [ALL]`

Two further knobs are commented out in the defaults and worth enabling for
production once you have verified the workload tolerates them:

```yaml
agent:
  securityContext:
    readOnlyRootFilesystem: true
management:
  securityContext:
    readOnlyRootFilesystem: true
```

Verify with a smoke deploy before rolling broadly — `readOnlyRootFilesystem`
will surface any code path that writes outside an explicit `emptyDir` mount.
The init containers and identity-injector already run with
`readOnlyRootFilesystem: true` by default.

## NetworkPolicy

The chart provisions default-deny `NetworkPolicy` resources for every
project namespace, with a curated egress block list (RFC1918 + 169.254
link-local) and an allow-list mechanism for explicit destinations. This is
on by default and well-suited for production — see the **Network Policies**
section of the [chart README](../../charts/catalyst/README.md) for the
allow/deny model and how to extend it. Note that enforcement requires a CNI
that supports `NetworkPolicy` (Calico, Cilium, Azure NPM, AWS VPC CNI with
`ENABLE_NETWORK_POLICY=true`, or kube-router).

## Deployment-specific values not in the overlay

These are environment-specific and belong in your own values file, not the
public overlay:

- **PostgreSQL connection details** — host, credentials, TLS. See
  [Managed infrastructure](#managed-infrastructure) above.
- **Image registries** — `global.image.registry` and the various
  per-component `image_registry` knobs. 
- **NATS endpoints, Sentry trust anchors** — region-specific.
- **Secrets provider** — `global.secrets.provider`. See the Secrets section
  of the chart README.

## Verifying the overlay

```bash
helm lint charts/charts/catalyst/ -f charts/charts/catalyst/values-production.yaml

helm template catalyst charts/charts/catalyst/ \
  -f charts/charts/catalyst/values-production.yaml \
  > /tmp/prod-render.yaml
```

Spot-checks on the rendered output:

- No `resources.limits` block on the `agent` or `management` Deployments.
- No `GOMEMLIMIT` env var on the `agent` or `management` containers.
- Management HPA present with `minReplicas: 2`, `maxReplicas: 5`.
- Gateway/Envoy HPA present with `minReplicas: 3`, `maxReplicas: 10`,
  `targetCPUUtilizationPercentage: 70`.
