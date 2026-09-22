# Release Channels and Upgrades

How to decide which version of Catalyst your self-managed region installs next,
and how to automate that decision.

There are three ways to do it. They differ in one thing: **who decides**. Point
your tooling at a channel repository and the registry decides. Act on the answer
Diagrid publishes and the release policy decides — channel heads, blocks, freeze
windows, entitlements and tested upgrade paths all apply.

What does not differ is who applies the upgrade. In all three it is you.

> **You never call the resolver yourself, and you do not need to.** The
> endpoint admits exactly one caller — your region's own agent, holding a
> short-lived certificate it fetches at startup and keeps in memory — so there
> is nothing for automation you write to present. Instead the agent asks on
> your behalf on a schedule and publishes the answer into your cluster as a
> ConfigMap, which your tooling reads with ordinary Kubernetes access. See
> [The published answer](#the-published-answer).
>
> Publishing the answer is all Diagrid does. **It never installs, upgrades or
> edits anything in your cluster** — not your Argo CD `Application`, not your
> Flux `HelmRelease`, not a Helm release. You decide what to do with the answer
> and you apply it. See [Who may call the resolver](#who-may-call-the-resolver).
>
> **Which environments serve it:** staging, at
> `https://catalyst-releases.staging.diagrid.dev`. A region joined to staging
> can configure that address today and will get a published answer. Production
> is not served yet, so a production region has nothing to configure and no
> answer to publish — that is expected and is not a certificate, network or
> configuration fault at your end. **Pattern A works in both.** Diagrid will
> record the production endpoint in its product release notes when it goes live,
> and support can confirm the current status.

For the first install and the join token, start with
[Getting Started](../getting-started/README.md).

## At a glance

| | Pattern A — registry range | Pattern B — answer to Git | Pattern C — in-cluster job |
|---|---|---|---|
| Where your tooling reads the decision | The registry's newest chart | The published ConfigMap | The published ConfigMap |
| Upgrade arrives as | A new chart in the registry | A commit in your repository | A change your job applies |
| Channel head enforced | No | Yes | Yes |
| Blocked release withheld | No | Yes | Yes |
| Freeze windows honoured | No | Yes | Yes |
| Tested upgrade path followed | No | Yes | Yes |
| Your review/approval applies | Depends on your flow | Yes, unchanged | Only what your job offers |
| Who applies the upgrade | You | You | You |
| Level | 1 | 2 | 2 |
| Available today | **Yes** | No — see the note above | No — see the note above |
| Recommended | For evaluation | **Yes, once it is available** | When you cannot run a job outside the cluster |

In every pattern the last row is the same: **you apply the upgrade.** Diagrid
tells you what release you should be on; it never reaches into your cluster to
put you there.

## Pattern A — registry range (level 1)

Point existing tooling at a channel repository and take whatever it reports as
newest. Nothing calls Diagrid.

```bash
helm upgrade --install catalyst oci://public.ecr.aws/diagrid/stable/catalyst \
     -n cra-agent \
     -f catalyst-values.yaml
```

> **Level 1 limit.** A registry path is not policy enforcement. The registry has
> no idea which release your region is entitled to, which one Diagrid has
> blocked, whether you are inside a change freeze, or whether there is a tested
> upgrade path from the version you are running to the one it is about to hand
> you. It reports the newest chart it holds. That is all it can do.
>
> With auto-sync on, this also applies a new release **the moment it is
> published** — no soak, no window, no review.

Pinning the version narrows the blast radius but does not change the level:

```bash
helm upgrade --install catalyst oci://public.ecr.aws/diagrid/stable/catalyst \
     --version 1.120.0 \
     -n cra-agent \
     -f catalyst-values.yaml
```

> **Level 1 limit.** Still no channel head enforcement, no block, no freeze, no
> graph edges. You have chosen a version by hand; nothing has checked that the
> upgrade from what you run today to 1.95.0 has been tested, or that 1.95.0 is
> still a release Diagrid will support you on.

### The same thing under Argo CD

A semver range in `targetRevision`. Argo CD re-resolves it on every sync and
takes the highest published version that matches.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: catalyst
  namespace: argocd
spec:
  project: catalyst
  source:
    # Register this registry as a Helm repository with OCI enabled before the
    # Application will resolve. Argo CD 3.x also accepts an "oci://" prefix.
    repoURL: public.ecr.aws/diagrid
    chart: catalyst
    targetRevision: ">=1.93.0 <2.0.0"
    helm:
      releaseName: catalyst
      values: |
        # the contents of your catalyst-values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: cra-agent
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
# Sync windows are a property of the AppProject, not of the Application. With
# one or more "allow" windows defined, automatic syncs happen only inside them.
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: catalyst
  namespace: argocd
spec:
  sourceRepos:
    - public.ecr.aws/diagrid
  destinations:
    - server: https://kubernetes.default.svc
      namespace: cra-agent
  syncWindows:
    # Tuesdays, 09:00-11:00 UTC. Outside the window a person can still sync by
    # hand, because manualSync is true.
    - kind: allow
      schedule: "0 9 * * 2"
      duration: 2h
      timeZone: UTC
      applications:
        - catalyst
      manualSync: true
```

### The same thing under Flux

An OCI `HelmRepository` and a `HelmRelease` carrying the same range. Needs Flux
2.3 or later for these API versions.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: diagrid
  namespace: cra-agent
spec:
  type: oci
  url: oci://public.ecr.aws/diagrid
  interval: 1h
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: catalyst
  namespace: cra-agent
spec:
  # Set this to true to stop Flux applying anything new without uninstalling
  # the release. It is the Flux equivalent of an Argo CD sync window, and it is
  # lifted by hand.
  suspend: false
  interval: 1h
  releaseName: catalyst
  chart:
    spec:
      chart: catalyst
      version: ">=1.93.0 <2.0.0"
      sourceRef:
        kind: HelmRepository
        name: diagrid
        namespace: cra-agent
      interval: 1h
  values: {}
```

> **Level 1 limit.** Both of these are Pattern A with a scheduler attached. The
> range is resolved by the registry, so nothing has checked which release your
> region is entitled to, no block will withhold one, no freeze window will hold
> one back, and no tested upgrade path connects what you run today to what you
> are about to be given. Argo CD's automated sync and Flux's `interval` each
> apply a matching release **the moment it is published** — no soak, no window,
> no review.
>
> The only delay available at this level is one you schedule yourself: an Argo
> CD sync window, or `suspend: true` on the `HelmRelease` until you lift it.
> Neither is policy. They gate *when* you take whatever the registry offers,
> never *what* it is allowed to offer you.

Use Pattern A for a first look. For anything you intend to keep running, use
Pattern B.

## Pattern B — published answer to Git, then GitOps (recommended)

A scheduled job reads the answer the agent published, writes it into your own
repository, and your existing GitOps flow applies the commit. Diagrid never
reaches into your cluster.

This is the recommended pattern because of what it composes with rather than
what it adds:

- **The upgrade arrives as a reviewable commit.** A version bump shows up as a
  diff, in the repository your team already watches, with the reason the control
  plane gave for it.
- **Your approval rules apply unchanged.** Branch protection, required
  reviewers, CODEOWNERS, deployment windows in your CD system — all of it keeps
  working, because the upgrade is an ordinary commit and not a side channel
  around your process.
- **Multi-hop handles itself.** Each answer carries one hop. Once that hop is
  running, the agent's next refresh publishes the next hop and your next
  scheduled run reads it. You do not plan the path, and you never pick an
  intermediate version by hand.

### The resolver

```
GET https://<resolver-endpoint>/apis/cra.diagrid.io/v1beta2/region/release/next
```

Your region's agent calls this; you do not. It is documented here because the
answer it returns is exactly what lands in the ConfigMap your tooling reads, so
the field reference below is the reference for both. The address is a property
of the control plane your region joined — `catalyst-releases.staging.diagrid.dev`
for staging — and you give it to the agent through one chart value, see
[The published answer](#the-published-answer).

#### Who may call the resolver

Only your region's own agent.

That is settled during the TLS handshake, before a byte of HTTP is read. The
endpoint requires a client certificate, checks it was issued by Diagrid's own
certificate authority, and then requires the identity inside it to be the region
agent's specifically — not merely *something* inside your region. A workload of
your own running in a Catalyst project holds a certificate from that same
authority and is still refused, which is precisely why the check is written the
way it is.

The agent fetches that certificate when it starts, renews it on its own, and
holds it in memory. It is never written to a file, a Kubernetes Secret, or
anywhere else you could mount or copy it. **So you cannot point your own script
at the resolver**, and no chart value or configuration setting changes that.

You do not need to. Switch on [The published
answer](#the-published-answer) and the agent asks on your behalf, on an
interval, writing what it gets into a ConfigMap in its own namespace. Your
tooling reads that with ordinary Kubernetes access and no Diagrid credential at
all.

#### The request

This is the call your region's agent makes, described here because the answer it
returns is what you read. You cannot make it yourself — see above — and you do
not configure any of it beyond the endpoint address.

`GET`, with no body. Every parameter is optional.

| Parameter | Meaning |
|---|---|
| `component` | What the answer is about. Defaults to `catalyst-dataplane`, which is the component a region installs. An unknown value is rejected. |
| `organizationId`, `regionId`, `hostId` | An optional echo of the identity the agent believes it has, so a misconfigured agent finds out rather than quietly receiving an answer meant for somewhere else. |

**Nothing in the request chooses which region is answered for.** The endpoint
takes the organization and the region from the agent's certificate, and the
region's internal identifier from its own record rather than from anything the
agent sent. The three parameters above are checked *against* the identity the
agent authenticated as and are never used in its place: one that disagrees is
refused outright, and no answer comes back at all.

That is the difference between a policy that could be stepped around by editing
a request and one that cannot. If a region id were an input, any region's
credential would answer for every region.

A region that has an upgrade waiting gets:

```json
{
  "catalogGeneration": "sha256:6f8a…",
  "component": "catalyst-dataplane",
  "target": { "kind": "region", "name": "eu-west-7", "uid": "0f2c…" },
  "channel": "stable",
  "mode": "follow",
  "currentRelease": {
    "component": "catalyst-dataplane",
    "version": "1.93.0",
    "manifestDigest": "sha256:11ab…"
  },
  "channelHead": { "component": "catalyst-dataplane", "version": "1.95.0", "manifestDigest": "sha256:33cd…" },
  "destination": { "component": "catalyst-dataplane", "version": "1.95.0", "manifestDigest": "sha256:33cd…" },
  "nextRelease": { "component": "catalyst-dataplane", "version": "1.94.0", "manifestDigest": "sha256:22bc…" },
  "nextChart": {
    "repository": "oci://public.ecr.aws/diagrid/catalyst",
    "digest": "sha256:9e41…",
    "reference": "oci://public.ecr.aws/diagrid/catalyst@sha256:9e41…",
    "mediaType": "application/vnd.cncf.helm.chart.content.v1.tar+gzip"
  },
  "reason": "NEXT_HOP_SELECTED",
  "support": { "status": "available" },
  "issuedAt": "2026-08-30T09:00:00Z",
  "expiresAt": "2026-08-30T09:15:00Z",
  "digest": "sha256:c07d…"
}
```

### Reading the answer

| Field | What it is |
|---|---|
| `nextRelease` | **The one release to install now.** Absent when your region must not move. |
| `nextChart.reference` | Where to install it from, pinned by digest. This is the only installation authority in the response. Absent whenever `nextRelease` is. |
| `nextChart.repository` / `.digest` / `.mediaType` | The same coordinate in parts, for tooling that wants them separately. There is no tag field. |
| `destination` | Where your region is ultimately heading. **Not what to install.** |
| `reason` | Why this answer came out this way. Stable codes; match on these, not on prose. |
| `frozenUntil` | When the freeze covering your region lifts. Present only with `FREEZE_WINDOW_ACTIVE`. |
| `decisionRequired` | A hold or pin on your region has reached its review date. It never appears alongside permission to move. |
| `support` | The status and end-of-support date of the release you will be running once you apply this answer — the hop when you move, what you are already on when you do not. |
| `currentRelease` | What Diagrid observed your region to be running. Absent when nothing is known, which is itself a reason to do nothing rather than to install afresh. |
| `channelHead` | The release the channel you follow currently points at. |
| `channel` / `mode` | The channel your subscription follows, and what it is doing about it — `follow`, `hold` or `pin`. |
| `component` | What the answer is about. `catalyst-dataplane` unless you asked otherwise. |
| `target` | The region the answer was computed for, as Diagrid knows it. Echoed back so you can confirm which region you were answered as — never to choose one. |
| `issuedAt` / `expiresAt` | When the answer was computed, and when it stops being usable. |
| `catalogGeneration` | Which state of the Diagrid catalog the answer was computed against. It moves whenever any release or channel head does, whether or not your answer moves with it. |
| `digest` | Covers every field above, `expiresAt` included. |

Fields that are not set are absent from the response rather than present and
empty, so an answer that refuses to move you carries no `nextRelease` and no
`nextChart` at all — there is nothing for a caller to misread as an instruction.

Three properties are worth stating plainly, because tooling that assumes
otherwise breaks in ways that look like something else:

**`nextRelease` is one hop, not the destination.** On a multi-hop upgrade it
names an intermediate release. Apply it, wait for it to converge, and **read the
published answer again** — once the agent's next refresh sees the new current
release, what it publishes carries the next hop. Tooling that treats the first
answer as final stops part-way up the chain and looks stuck on a version nobody
chose. The region is not stuck; nobody ever read its next hop.

**Never install by tag.** The response contains no tag anywhere, and that is
deliberate. A tag is a mutable pointer: the chart it names today is not
necessarily the chart it named when the release was published. `nextChart.digest`
is the content, and `nextChart.reference` is what to install.

**It expires, and then it fails closed.** An answer is deliberately short-lived
— fifteen minutes today — because it is the only thing standing between a policy
change and a region that installs anyway. A block placed on a bad build, or a
freeze window opening, has to reach you quickly enough that whoever stopped the
rollout sees it stop.

`expiresAt` states the exact moment, so read it rather than assuming a duration.
The answer is usable up to that instant and not at it. `digest` covers
`expiresAt` along with every other field, so a cached answer whose expiry has
been edited to buy time no longer matches the digest it carries: the expiry
cannot be detached from the decision it belongs to.

Past `expiresAt` you have no instruction, which is deliberately the same state
as never having asked. If you cannot reach Diagrid for a fresh one, your region
keeps running what it is running. Do not fall back to a channel, a tag, or the
newest thing in a registry.

### Answers that do not move you

An answer with no `nextRelease` is an ordinary outcome, not an error. Exactly
one `reason` is set on every answer, `NEXT_HOP_SELECTED` on the ones that move
you and one of these on the ones that do not:

| `reason` | Meaning |
|---|---|
| `ALREADY_AT_DESTINATION` | Nothing to do. You are on the release your subscription points at. |
| `FREEZE_WINDOW_ACTIVE` | A change freeze covers now. `frozenUntil` says when it lifts. |
| `RELEASE_BLOCKED` | Diagrid has stopped rollouts to that release. It will not be offered while the block stands. |
| `RELEASE_RETIRED` | That release has left support and is no longer a valid upgrade target. |
| `SUBSCRIPTION_HELD` / `SUBSCRIPTION_PINNED` | Your own policy is holding the region where it is. |
| `PINNED_RELEASE_UNRESOLVED` | The version your subscription pins does not name exactly one release in the catalog. |
| `NOT_ENTITLED` | Your plan does not cover the channel your subscription names. |
| `CHANNEL_HEAD_UNKNOWN` | Diagrid has not recorded where that channel currently points, so there is nowhere to resolve towards. |
| `POLICY_CAPTURE_PENDING` | A hold on your region has not captured the policy it applies yet. |
| `NO_SUPPORTED_UPGRADE_PATH` | No chain of tested upgrades connects what you run to where you are heading. |
| `DOWNGRADE_NOT_ALLOWED` | Where you are heading is older than what you run, and your subscription does not permit moving backwards. |
| `AGENT_VERSION_TOO_OLD` | The agent must be upgraded before that release can be installed. |
| `CURRENT_RELEASE_UNKNOWN` | Diagrid cannot tell what you are running, so it will not tell you what to install next. |

The codes are a closed, stable set: a new situation gets a new code rather than
a reworded old one, so matching on them is safe. Treat any code you do not
recognise the way you treat the ones above.

Treat every one of these as "do nothing this run" and read the ConfigMap again
on the next schedule. Most clear by themselves. The ones that will not, and that need
someone, are `NOT_ENTITLED`, `NO_SUPPORTED_UPGRADE_PATH`,
`AGENT_VERSION_TOO_OLD`, `PINNED_RELEASE_UNRESOLVED`, `DOWNGRADE_NOT_ALLOWED`
and `RELEASE_RETIRED`.

### When the call itself fails

A refusal to move you is an answer with a `reason`, and arrives as `200`. These
are the cases where there is no answer at all:

| Status | What it means |
|---|---|
| `400` | The call was wrong: an unknown `component`, or a scope parameter that disagrees with the agent's certificate. The credential is fine; the call is not. |
| `401` | Diagrid could not tell which region was calling. No client certificate, or one carrying no region identity. |
| `403` | The caller is authenticated, but Diagrid will not answer for that region — it has no record of it, or the region is being deleted. |
| `5xx` | Diagrid could not answer. Nothing changes, and the agent asks again on its next refresh. |

The distinction between `400` and `403` is worth respecting when you read one in
`refreshError`. A `403` sends someone to certificates and entitlements; a `400`
means the call itself was malformed, and reporting one as the other costs an
afternoon.

Failures carry no response body — the message is in the `error-msg` response
header. A caller that is not a region agent at all does not reach any of this:
it is refused during the TLS handshake and gets no HTTP status.

A successful answer is sent with `Cache-Control: no-store`, so no network
intermediary between your region and Diagrid may keep a copy: the answer carries
its own expiry, and a proxy or CDN serving it past that point would be handing
out an instruction that has already been withdrawn.

The agent is the caller, so this is not a status code you will see. What you see
is the `refreshError` key of the published ConfigMap, which carries the status
and that `error-msg` header verbatim — and the table above is how to read it.

The agent is not one of those intermediaries either. It keeps the last answer in
the ConfigMap deliberately, past the expiry included, so you can see what went
stale rather than finding nothing at all — which is what `state` and `expiresAt`
are for. See [`state` is the first thing to
read](#state-is-the-first-thing-to-read).

### The published answer

Your tooling does not call the resolver. The agent does, on an interval, and
writes what it gets into a ConfigMap in its own namespace. Your pipeline reads
that ConfigMap with ordinary Kubernetes access — no Diagrid certificate, no
secret to mount, nothing to rotate.

**Diagrid does not apply the upgrade.** The agent publishes the answer and stops
there. It does not run Helm, it does not edit your Argo CD `Application` or your
Flux `HelmRelease`, and it does not touch any workload the chart installed.
Deciding what to do with the answer, and applying it, remains yours — as it is
in Pattern A. Turning this on gives you a policy-checked answer to act on; it
does not hand over control of your cluster, and it does not take on
responsibility for keeping your region up to date.

#### Turning it on

Two values, plus an optional third, in your `catalyst-values.yaml`.

```yaml
agent:
  config:
    release_availability:
      # Off by default.
      enabled: true
      # The address Diagrid published for the resolver, for the control plane
      # this region joined. Required: there is no default, and the publisher
      # does not start without one.
      endpoint: https://catalyst-releases.staging.diagrid.dev
      # Optional. How often to refresh, in seconds. Keep it well inside the
      # fifteen minutes an answer is good for, so a failed refresh or two does
      # not leave you with an expired answer. Five minutes is the default.
      interval_in_sec: 300
```

Then upgrade the chart as you normally would. Within a minute of the agent
restarting there is a ConfigMap called `catalyst-release-availability` in the
`cra-agent` namespace.

**Both `enabled` and `endpoint` are needed.** `enabled: true` on its own does
not start the publisher: the agent logs a warning, writes no ConfigMap at all,
and everything else about the region carries on unaffected. Until an address is
configured there is nothing to read.

A region joined to staging has an address to put here today. For a production
region there is none yet — see the note at the top of this page — so `endpoint`
stays empty and no ConfigMap appears. Once an address is configured but not yet
served, the ConfigMap does appear and says `state: unavailable` with the failure
in `refreshError`. Either way your region runs exactly as it did, so wiring the
values in ahead of time is safe and is how to have your pipeline written before
then.

#### What it looks like

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: catalyst-release-availability
  namespace: cra-agent
data:
  # Branch on this first. See the table below.
  state: current

  # Why this answer came out this way. Stable codes; match on these.
  reason: NEXT_HOP_SELECTED
  component: catalyst-dataplane
  channel: stable
  mode: follow

  # The one release to install now, and where to install it from. Empty
  # whenever your region must not move.
  nextVersion: 1.94.0
  nextReleaseDigest: sha256:65d4786…
  nextChartReference: oci://public.ecr.aws/diagrid/catalyst@sha256:b04825e…
  nextChartRepository: oci://public.ecr.aws/diagrid/catalyst
  nextChartDigest: sha256:b04825e…

  # What Diagrid observed your region to be running.
  currentVersion: 1.93.0
  currentReleaseDigest: sha256:2c804b7…

  # When the answer was computed and when it stops being usable.
  issuedAt: "2026-08-30T09:00:00Z"
  expiresAt: "2026-08-30T09:15:00Z"

  # When the agent last tried, and why it did not get an answer. Empty when
  # the last attempt succeeded — the key is always present.
  lastRefreshAt: "2026-08-30T09:01:00Z"
  refreshError: ""

  # The resolver's answer, verbatim — the bytes as they arrived. Everything
  # above is derived from this; read it for anything the flat keys do not
  # carry: frozenUntil, support dates, the answer's own digest, or a field
  # added to the answer since your agent was built. See "Reading the answer"
  # above.
  answer.json: |
    { … }
```

Every key is a plain single-line string apart from `answer.json`, so a shell
script needs nothing but `kubectl` and `jsonpath`:

```bash
kubectl get configmap catalyst-release-availability -n cra-agent \
        -o jsonpath='{.data.nextVersion}'
```

#### `state` is the first thing to read

| `state` | What it means | What to do |
|---|---|---|
| `current` | The published answer had not expired when it was written. | Act on it. |
| `expired` | The answer is past its own `expiresAt`. Diagrid has been unreachable for longer than an answer lives. | **Do nothing.** Keep running what you are running, and look at why the refresh is failing — `refreshError` says. |
| `unavailable` | No answer has ever been obtained. | **Do nothing.** `refreshError` says why. |

`state` is recomputed on every refresh, including the failed ones, so an answer
that ages out while Diagrid is unreachable becomes visibly `expired` rather than
sitting there looking valid.

It is only ever as fresh as the last refresh, though — up to one
`interval_in_sec` behind in the ordinary case, and indefinitely behind if the
agent itself has stopped, because then nothing rewrites it at all.
**`expiresAt` is the authority**: compare it against the clock, as the script
below does, and read `lastRefreshAt` to see whether anything is still trying.

Past `expiresAt` you have no instruction, deliberately the same state as never
having asked. Do not fall back to a channel, a tag, or the newest thing in a
registry — see [Do not use a cached answer past
`expiresAt`](#what-not-to-do).

#### A failed refresh never costs you the last answer

When the agent cannot get a fresh answer it leaves the one already published
exactly as it stands and records the failure in `refreshError` and
`lastRefreshAt`. It never deletes the ConfigMap and never writes half an answer.
So the three things you can be looking at are:

- **A fresh answer.** `state: current`, `refreshError` empty.
- **A previous answer plus a failure.** `state: current` while it is still
  inside its expiry, `refreshError` populated. Your pipeline may still act on
  it, and someone should look at the error.
- **A stale answer plus a failure.** `state: expired`. Act on nothing.

Refreshing also pauses while the agent restarts or rolls. On a multi-replica
agent exactly one replica refreshes, elected by a Kubernetes Lease, so a
handover pauses it too: seconds when the outgoing replica shuts down cleanly and
releases the lease, and up to the lease's own duration when it dies without
doing so. Every one of those gaps is far shorter than the fifteen minutes an
answer lives. The last answer stays put throughout and `lastRefreshAt` shows the
gap, so there is nothing to do about it unless the gap keeps growing.

Turning off `enabled` stops the refreshes; the last ConfigMap stays behind and
goes on ageing, so delete it if you no longer want anything reading it.

#### Letting your pipeline read it

Name whatever runs your upgrade job, and the chart grants it read access to
that one ConfigMap and nothing else:

```yaml
agent:
  config:
    release_availability:
      enabled: true
      readers:
        - name: catalyst-upgrade   # the ServiceAccount your job runs as
          namespace: ci
```

That renders a `Role` granting `get` on the single ConfigMap plus the
`RoleBinding` that gives it to you. It takes both halves: nothing is rendered
unless `enabled` is true AND at least one reader is named. So if you manage RBAC
yourself, leave `readers` unset and apply your own:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: catalyst-release-availability-reader
  namespace: cra-agent
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["catalyst-release-availability"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: catalyst-release-availability-reader
  namespace: cra-agent
subjects:
  - kind: ServiceAccount
    name: catalyst-upgrade
    namespace: ci
roleRef:
  kind: Role
  name: catalyst-release-availability-reader
  apiGroup: rbac.authorization.k8s.io
```

The Role deliberately grants `get` and not `list` or `watch`: neither can be
restricted to a single object name, so granting them would widen the binding to
every ConfigMap in `cra-agent` — including the one holding your region's join
details.

### The scheduled job

Read the published answer, and write it into your repository. Nothing here
applies anything to a cluster.

```bash
#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=cra-agent
CONFIGMAP=catalyst-release-availability

# Every value is a plain single-line string, so one jsonpath read per key is the
# whole of the parsing. A missing ConfigMap fails here, loudly, which is right:
# it means no endpoint is configured, the publisher is switched off, or the
# agent has not registered and published its first answer yet.
answer_key() {
  kubectl get configmap "${CONFIGMAP}" -n "${NAMESPACE}" -o "jsonpath={.data.$1}"
}

STATE=$(answer_key state)
REFRESH_ERROR=$(answer_key refreshError)

case "${STATE}" in
  current)
    # Still worth reporting: the answer is usable, but the agent's last attempt
    # to refresh it did not land.
    if [ -n "${REFRESH_ERROR}" ]; then
      echo "warning: last refresh failed, acting on the answer already published: ${REFRESH_ERROR}" >&2
    fi
    ;;
  expired)
    echo "the published answer expired at $(answer_key expiresAt); Diagrid has been unreachable: ${REFRESH_ERROR}" >&2
    exit 1
    ;;
  unavailable)
    echo "no answer has been published yet: ${REFRESH_ERROR}" >&2
    exit 1
    ;;
  *)
    # Fail closed on a state this script does not know, exactly as you would on
    # an unrecognised reason code.
    echo "unrecognised state '${STATE}'; doing nothing" >&2
    exit 1
    ;;
esac

# expiresAt is the authority — state is only as fresh as the last refresh. The
# timestamps are fixed-width RFC 3339 in UTC, so comparing them as strings is
# correct and needs no date arithmetic. Usable up to that instant, not at it.
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EXPIRES_AT=$(answer_key expiresAt)
if [[ ! "${NOW}" < "${EXPIRES_AT}" ]]; then
  echo "the published answer expired at ${EXPIRES_AT}; doing nothing" >&2
  exit 1
fi

REASON=$(answer_key reason)
VERSION=$(answer_key nextVersion)

# No hop is the common case: already there, frozen, held, blocked. Say so and
# stop. Do NOT fall back to a tag or to the newest chart in the registry.
if [ -z "${VERSION}" ]; then
  echo "no upgrade this run: ${REASON}"
  exit 0
fi

CHART_DIGEST=$(answer_key nextChartDigest)
CHART_REF=$(answer_key nextChartReference)

# Write the pin into your own repository. Nothing here touches a cluster.
yq -i ".catalyst.version = \"${VERSION}\" |
       .catalyst.chartDigest = \"${CHART_DIGEST}\" |
       .catalyst.chartReference = \"${CHART_REF}\"" \
   clusters/eu-west-7/catalyst-version.yaml

git checkout -b "catalyst-${VERSION}"
git commit -am "Catalyst ${VERSION} for eu-west-7 (${REASON})"
git push origin "catalyst-${VERSION}"
gh pr create --fill
```

Run it on whatever schedule suits you — every 15 minutes or once a night. A run
that has nothing to do exits without touching the repository, so a frequent
schedule costs nothing but shortens the gap between a release being promoted and
the pull request appearing. Reading the ConfigMap costs Diagrid nothing at all:
the refresh happens on the agent's own interval whether you read it or not.

Because each answer carries one hop, a region three releases behind produces
three successive pull requests, each one reviewed and applied before the next is
raised. The agent asks again on its interval, sees the new current release once
your commit lands, and publishes the next hop. That is the multi-hop path,
handled by the schedule rather than by anyone planning it.

### Applying the commit

Whatever you already use. With Flux, the digest is the source of truth — this
one needs Flux 2.6 or later for `OCIRepository` at `v1`, and a `HelmRelease`
pointing at it through `chartRef`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: catalyst
  namespace: cra-agent
spec:
  interval: 10m
  url: oci://public.ecr.aws/diagrid/catalyst
  ref:
    # Written by the scheduled job from nextChart.digest. Pinning the digest
    # rather than the tag is what makes this reproducible.
    digest: sha256:9e41…
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: catalyst
  namespace: cra-agent
spec:
  interval: 10m
  releaseName: catalyst
  # No chart name and no version range: the OCIRepository above already names
  # the exact bytes, so there is nothing left for Flux to choose.
  chartRef:
    kind: OCIRepository
    name: catalyst
    namespace: cra-agent
  values: {}
```

With plain Helm, check the digest before you install. Helm installs by version,
so confirm that the version tag still resolves to the artifact Diagrid named:

```bash
PUBLISHED=$(crane digest "public.ecr.aws/diagrid/catalyst:${VERSION}")
test "${PUBLISHED}" = "${CHART_DIGEST}" \
  || { echo "the ${VERSION} tag no longer points at the chart Diagrid named; refusing to install"; exit 1; }

helm upgrade --install catalyst oci://public.ecr.aws/diagrid/catalyst \
     --version 1.120.0"${VERSION}" \
     -n cra-agent -f catalyst-values.yaml
```

The check is not optional ceremony. `--version` names a tag, and a tag can be
moved; the check is what turns "install version 1.94.0" into "install the exact
chart Diagrid published as 1.94.0". Any tool that reads an OCI manifest digest
works here — `crane digest`, `oras manifest fetch --descriptor`, `skopeo
inspect`. Where your GitOps engine can pin the digest itself, as Flux does
above, prefer that: it removes the window between the check and the install.

## Pattern C — in-cluster job (level 2)

When you cannot run a job outside the cluster, run the same loop inside it. It
is Pattern B's logic with the Git step removed: read the published answer, then
apply it.

The policy that applies is identical — same answer, same channel head, blocks,
freeze windows and tested edges. What you give up is the reviewable commit. The
upgrade happens because your job acted on an answer, not because someone merged
a change, and your GitOps history will not show it.

> **There is no Diagrid-supplied upgrade controller, and there will not be
> one.** Diagrid publishes the answer and applies nothing; the job that acts on
> it is yours, running with your permissions, on your schedule. That boundary is
> deliberate — see [The published answer](#the-published-answer).

Pattern C is a `CronJob` you write and run yourself:

- **On a schedule well inside the answer's own `expiresAt` window**, so the job
  never acts on something it has been holding too long. Every five minutes
  against a fifteen-minute expiry, say, with `concurrencyPolicy: Forbid`.
- **Running Pattern B's script**, with the `git` and `gh` lines replaced by the
  digest verification and the `helm upgrade` shown above. Keep the verification
  step: it is what makes this an upgrade to the exact chart Diagrid named. Keep
  the `state` check too — it is what stops the job acting on an answer that has
  aged out while Diagrid was unreachable.
- **With a ServiceAccount holding only what it needs**: the reader `RoleBinding`
  from [Letting your pipeline read
  it](#letting-your-pipeline-read-it), plus whatever upgrading the Catalyst
  release in its own namespace requires. It applies whatever it is told to, so
  its permissions are the ceiling on what a wrong answer could do.

Use Pattern C when running a job outside the cluster is genuinely not an option.
Otherwise prefer Pattern B, whose whole advantage is that the upgrade goes
through the review process you already have.

## What not to do

**Do not read the answer once and hard-code it.** The answer is a decision about
a moment — the catalog as it stood, the blocks in force, the freeze windows
open, the release you were running. Copying `nextVersion` into a values file
that nobody re-derives defeats every policy behind it: the block placed tomorrow
will not reach you, the freeze window will not stop you, and the next hop will
never be offered. Re-read the ConfigMap on a schedule, always.

**Do not treat a registry path as policy enforcement.** `oci://…/stable/catalyst`
is a location, not a guarantee. It carries no channel head enforcement, no
block, no freeze and no upgrade-graph edges — that is the level-1 limit, and no
amount of pinning inside Pattern A changes it. If you need any of those things,
you need [the published answer](#the-published-answer).

**Do not install by tag once you are past evaluation.** Pin the digest. A tag
can be moved; a digest cannot.

**Do not try to borrow the region agent's identity.** The resolver admits the
agent and nothing else — a workload of yours holding a certificate from the same
authority is still refused. The agent's certificate is short-lived and held in
memory, so there is nothing to copy, and an identity that two workloads both
claim would be worse than the arrangement that replaces it: the agent asks and
publishes, and your tooling reads the ConfigMap.

**Do not use a cached answer past `expiresAt`.** During a control-plane outage,
keep running what you are running. A stale answer and no answer differ only in
how convincing they look.

## Next steps

- [Getting Started](../getting-started/README.md) — signup, join token, first install
- [Production tuning](../production/README.md) — running a region under real traffic
- [Air-gapped installs](../air-gapped/README.md) — mirroring charts and images
- [Catalyst chart reference](../../charts/catalyst/README.md) — all configurable Helm values
