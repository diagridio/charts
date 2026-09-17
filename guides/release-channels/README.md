# Release Channels and Upgrades

How to decide which version of Catalyst your self-hosted region installs next,
and how to automate that decision.

There are three ways to do it. They differ in one thing: **who decides**. Point
your tooling at a channel repository and the registry decides. Ask the Diagrid
resolver and the release policy decides — channel heads, blocks, freeze windows,
entitlements and tested upgrade paths all apply.

> **The resolver is not enabled yet.** Diagrid does not serve the resolver
> endpoint in its hosted environments today, so calls to it will not succeed —
> that is expected, and not a certificate, network or configuration fault at
> your end. Patterns B and C are documented now so the integration can be built
> ahead of time; Pattern A works today. Diagrid will record the resolver in its
> product release notes when it goes live, and support can confirm the current
> status.

For the first install and the join token, start with
[Getting Started](../getting-started/README.md).

## At a glance

| | Pattern A — registry range | Pattern B — resolver to Git | Pattern C — in-cluster controller |
|---|---|---|---|
| Calls Diagrid | No | Yes, from a scheduled job | Yes, from the cluster |
| Upgrade arrives as | A new chart in the registry | A commit in your repository | A change the controller applies |
| Channel head enforced | No | Yes | Yes |
| Blocked release withheld | No | Yes | Yes |
| Freeze windows honoured | No | Yes | Yes |
| Tested upgrade path followed | No | Yes | Yes |
| Your review/approval applies | Depends on your flow | Yes, unchanged | Only what the controller offers |
| Level | 1 | 2 | 2 |
| Recommended | For evaluation | **Yes** | When you cannot run a job outside the cluster |

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
     --version 1.116.0 \
     -n cra-agent \
     -f catalyst-values.yaml
```

> **Level 1 limit.** Still no channel head enforcement, no block, no freeze, no
> graph edges. You have chosen a version by hand; nothing has checked that the
> upgrade from what you run today to 1.95.0 has been tested, or that 1.95.0 is
> still a release Diagrid will support you on.

Use Pattern A for a first look. For anything you intend to keep running, use
Pattern B.

## Pattern B — resolver to Git, then GitOps (recommended)

A scheduled job asks Diagrid what your region should install next, writes the
answer into your own repository, and your existing GitOps flow applies the
commit. Diagrid never reaches into your cluster.

This is the recommended pattern because of what it composes with rather than
what it adds:

- **The upgrade arrives as a reviewable commit.** A version bump shows up as a
  diff, in the repository your team already watches, with the reason the control
  plane gave for it.
- **Your approval rules apply unchanged.** Branch protection, required
  reviewers, CODEOWNERS, deployment windows in your CD system — all of it keeps
  working, because the upgrade is an ordinary commit and not a side channel
  around your process.
- **Multi-hop handles itself.** The resolver returns one hop. When that hop is
  running, the next scheduled run asks again and gets the next edge. You do not
  plan the path, and you never pick an intermediate version by hand.

### The resolver

```
GET https://api.diagrid.io/apis/cra.diagrid.io/v1beta2/region/release/next
```

Authenticate with your region's own client certificate. **You do not send a
region id, an organization id or a namespace** — the endpoint derives all of
them from the certificate. There is no parameter for asking about a different
region, by design.

```bash
curl --silent --show-error \
     --cert  "$REGION_CLIENT_CERT" \
     --key   "$REGION_CLIENT_KEY" \
     "https://api.diagrid.io/apis/cra.diagrid.io/v1beta2/region/release/next"
```

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
| `nextChart.reference` | Where to install it from, pinned by digest. This is the only installation authority in the response. |
| `destination` | Where your region is ultimately heading. **Not what to install.** |
| `reason` | Why this answer came out this way. Stable codes; match on these, not on prose. |
| `support` | The status and end-of-support date of the release you will be running once you apply this answer. |
| `expiresAt` | When this answer stops being usable. |
| `catalogGeneration` | Which state of the Diagrid catalog the answer was computed against. |
| `digest` | Covers every field above, `expiresAt` included. |

Three properties are worth stating plainly, because tooling that assumes
otherwise breaks in ways that look like something else:

**`nextRelease` is one hop, not the destination.** On a multi-hop upgrade it
names an intermediate release. Apply it, wait for it to converge, and **ask
again** — the next answer carries the next edge. Tooling that treats the first
answer as final stops part-way up the chain and looks stuck on a version nobody
chose. The region is not stuck; it was never asked for its next hop.

**Never install by tag.** The response contains no tag anywhere, and that is
deliberate. A tag is a mutable pointer: the chart it names today is not
necessarily the chart it named when the release was published. `nextChart.digest`
is the content, and `nextChart.reference` is what to install.

**It fails closed.** If you cannot reach the control plane, your region keeps
running what it is running. Do not fall back to a channel, a tag, or the newest
thing in a registry. A cached answer may be used until `expiresAt` and never
after — past that you have no instruction, which is deliberately the same state
as never having asked.

### Answers that do not move you

An answer with no `nextRelease` is an ordinary outcome, not an error. The
`reason` says which:

| `reason` | Meaning |
|---|---|
| `ALREADY_AT_DESTINATION` | Nothing to do. You are on the release your subscription points at. |
| `FREEZE_WINDOW_ACTIVE` | A change freeze covers now. `frozenUntil` says when it lifts. |
| `RELEASE_BLOCKED` | Diagrid has stopped rollouts to that release. It will not be offered while the block stands. |
| `SUBSCRIPTION_HELD` / `SUBSCRIPTION_PINNED` | Your own policy is holding the region where it is. |
| `NOT_ENTITLED` | Your plan does not cover the channel your subscription names. |
| `NO_SUPPORTED_UPGRADE_PATH` | No chain of tested upgrades connects what you run to where you are heading. Contact support. |
| `AGENT_VERSION_TOO_OLD` | The agent must be upgraded before that release can be installed. |
| `CURRENT_RELEASE_UNKNOWN` | The control plane cannot tell what you are running, so it will not tell you what to install next. |

Treat every one of these as "do nothing this run" and try again on the next
schedule. Only `NO_SUPPORTED_UPGRADE_PATH`, `NOT_ENTITLED` and
`AGENT_VERSION_TOO_OLD` need a person.

### The scheduled job

Ask, and write the answer into your repository. Nothing here applies anything to
a cluster.

```bash
#!/usr/bin/env bash
set -euo pipefail

ANSWER=$(curl --silent --show-error --fail \
     --cert "$REGION_CLIENT_CERT" --key "$REGION_CLIENT_KEY" \
     "https://api.diagrid.io/apis/cra.diagrid.io/v1beta2/region/release/next")

REASON=$(jq -r '.reason' <<<"$ANSWER")

# No hop is the common case: already there, frozen, held, blocked. Say so and
# stop. Do NOT fall back to a tag or to the newest chart in the registry.
if [ "$(jq -r '.nextRelease // empty' <<<"$ANSWER")" = "" ]; then
  echo "no upgrade this run: ${REASON}"
  exit 0
fi

VERSION=$(jq -r '.nextRelease.version' <<<"$ANSWER")
CHART_DIGEST=$(jq -r '.nextChart.digest' <<<"$ANSWER")
CHART_REF=$(jq -r '.nextChart.reference' <<<"$ANSWER")

# Write the pin into your own repository.
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
the pull request appearing.

Because each run asks for one hop, a region three releases behind produces three
successive pull requests, each one reviewed and applied before the next is
raised. That is the multi-hop path, handled by the schedule rather than by
anyone planning it.

### Applying the commit

Whatever you already use. With Flux, the digest is the source of truth:

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
```

With plain Helm, check the digest before you install. Helm installs by version,
so confirm that the version tag still resolves to the artifact the resolver
named:

```bash
PUBLISHED=$(crane digest "public.ecr.aws/diagrid/catalyst:${VERSION}")
test "${PUBLISHED}" = "${CHART_DIGEST}" \
  || { echo "the ${VERSION} tag no longer points at the chart the resolver named; refusing to install"; exit 1; }

helm upgrade --install catalyst oci://public.ecr.aws/diagrid/catalyst \
     --version 1.116.0"${VERSION}" \
     -n cra-agent -f catalyst-values.yaml
```

The check is not optional ceremony. `--version` names a tag, and a tag can be
moved; the check is what turns "install version 1.94.0" into "install the exact
chart Diagrid published as 1.94.0". Any tool that reads an OCI manifest digest
works here — `crane digest`, `oras manifest fetch --descriptor`, `skopeo
inspect`. Where your GitOps engine can pin the digest itself, as Flux does
above, prefer that: it removes the window between the check and the install.

## Pattern C — in-cluster controller (level 2)

When you cannot run a job outside the cluster, run the same loop inside it. It
is Pattern B's logic with the Git step removed: ask, then apply.

The policy that applies is identical — same resolver, same answer, same channel
head, blocks, freeze windows and tested edges. What you give up is the reviewable
commit. The upgrade happens because a controller acted on an answer, not because
someone merged a change, and your GitOps history will not show it.

There is no Diagrid-supplied in-cluster upgrade controller to switch on today,
and no chart value that enables one. Pattern C is a `CronJob` you run:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: catalyst-upgrade
  namespace: cra-agent
spec:
  # Well inside the answer's own expiresAt window, so the job never acts on
  # something it has been holding too long.
  schedule: "*/10 * * * *"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          serviceAccountName: catalyst-upgrade
          volumes:
            - name: region-identity
              secret:
                secretName: catalyst-region-client-cert
          containers:
            - name: upgrade
              image: <an image with curl, jq and helm>
              volumeMounts:
                - name: region-identity
                  mountPath: /etc/catalyst/identity
                  readOnly: true
              env:
                - name: REGION_CLIENT_CERT
                  value: /etc/catalyst/identity/tls.crt
                - name: REGION_CLIENT_KEY
                  value: /etc/catalyst/identity/tls.key
              command: ["/bin/sh", "/scripts/upgrade.sh"]
```

The script is Pattern B's, with the `git`/`gh` lines replaced by the pull,
digest verification and `helm upgrade` shown above. Keep the verification step:
it is what makes this an upgrade to the exact chart the resolver named.

Give the job's ServiceAccount only what it needs to upgrade the Catalyst release
in its own namespace. It applies whatever the control plane tells it to, so its
permissions are the ceiling on what a wrong answer could do.

Use Pattern C when running a job outside the cluster is genuinely not an option.
Otherwise prefer Pattern B, whose whole advantage is that the upgrade goes
through the review process you already have.

## What not to do

**Do not resolve once and hard-code the answer.** The resolver's answer is a
decision about a moment — the catalog as it stood, the blocks in force, the
freeze windows open, the release you were running. Copying `nextRelease` into a
values file that nobody re-derives defeats every policy the resolver applies:
the block placed tomorrow will not reach you, the freeze window will not stop
you, and the next hop will never be offered. Re-ask on a schedule, always.

**Do not treat a registry path as policy enforcement.** `oci://…/stable/catalyst`
is a location, not a guarantee. It carries no channel head enforcement, no
block, no freeze and no upgrade-graph edges — that is the level-1 limit, and no
amount of pinning inside Pattern A changes it. If you need any of those things,
you need the resolver.

**Do not install by tag once you are past evaluation.** Pin the digest. A tag
can be moved; a digest cannot.

**Do not use a cached answer past `expiresAt`.** During a control-plane outage,
keep running what you are running. A stale answer and no answer differ only in
how convincing they look.

## Next steps

- [Getting Started](../getting-started/README.md) — signup, join token, first install
- [Production tuning](../production/README.md) — running a region under real traffic
- [Air-gapped installs](../air-gapped/README.md) — mirroring charts and images
- [Catalyst chart reference](../../charts/catalyst/README.md) — all configurable Helm values
