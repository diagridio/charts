# catalyst-dapr-chart publish pipeline

## What this is

`catalyst-dapr-chart` is an alternate-named Dapr Helm chart published to the
Diagrid AWS Marketplace (709) ECR so the AMMP container listing can ship a
Dapr chart that does not collide with Conductor's bare `diagrid/dapr` repo.

The chart source is **not vendored** in this repo. This directory holds only:

- `patches.yaml`   — 3 declarative yq edits applied to the fork source.
- `publish.py`     — wrapper script (clone fork, patch, validate, push).
- `Makefile`       — test/lint helpers.
- `tests/`         — pytest unit tests for the publish script.
- `README.md`      — this file.

Chart source-of-truth: the private Diagrid Dapr fork at
`github.com/diagridio/dapr-dapr`, in-repo at `charts/dapr/`. The fork tags
releases as `v<UPSTREAM>-catalyst.<N>`; the published chart artifact drops the
leading `v` (so fork tag `v1.17.5-catalyst.7` → chart `:1.17.5-catalyst.7`).

## Prerequisites

- `helm` >= 3.13 (OCI support), `yq` >= 4.40 (`strenv()`), `git`, `aws-cli`.
- Python 3.9+, `pyyaml` (`pip install pyyaml`).
- 709 ECR push creds via `marketplace-account` profile or assumed role:
  `aws ecr get-login-password ... | helm registry login --username AWS --password-stdin 709825985650.dkr.ecr.us-east-1.amazonaws.com`.
- One of (for fork access):
  - SSH key with read on `diagridio/dapr-dapr` (default `git clone` over SSH).
  - `GH_TOKEN` env var with `repo:read` on the fork (HTTPS clone — for CI).
  - Pre-cloned fork tree path, passed via `--fork-src` (skip-clone).

### Python dependency install

```bash
# From this directory:
make install-test-deps   # installs pytest + pyyaml + ruff into the active Python env
# or directly:
pip install pyyaml
```

## Versioning convention

- Chart: `<UPSTREAM>-catalyst.<N>` where `N` is a positive integer.
- Fork tag: `v<UPSTREAM>-catalyst.<N>` (same string with leading `v`).
- `N` resets to `1` whenever ANY component of `<UPSTREAM>` (major, minor, or
  patch) changes; otherwise increments monotonically.
- Look up next `N` via:
  `aws ecr describe-images --repository-name diagrid/catalyst-dapr-chart ... | jq '[.imageDetails[].imageTags[] | select(startswith("<UPSTREAM>-catalyst."))] | sort'`.

## Coordination with the Dapr-fork CI

`publish.py` does **not** build or push the `catalyst-dapr` image. That image
is built and mirrored to 709 ECR by the fork's own CI. Before running
`publish.py`, confirm the `--image-tag` you intend to reference already exists
in `709825985650.dkr.ecr.us-east-1.amazonaws.com/diagrid/catalyst-dapr:<tag>`;
otherwise the resulting chart will reference a missing image.

Note: `--catalyst-version` (the chart version) and `--image-tag` (the
container tag) are **separate** flags with no default-equivalence. Drift
between them is real and intentional — prod `:1.17.5-catalyst.6` chart
currently references `:1.17.5-catalyst.5-multi` image.

## Common version-bump procedure

```bash
# 1. Confirm next N is free in ECR.
aws ecr describe-images --profile marketplace-account --region us-east-1 \
  --repository-name diagrid/catalyst-dapr-chart \
  | jq '[.imageDetails[].imageTags[] | select(startswith("1.17.5-catalyst."))] | sort'

# 2. Confirm the fork tag exists.
gh api repos/diagridio/dapr-dapr/git/refs/tags/v1.17.5-catalyst.7

# 3. Confirm the catalyst-dapr image already exists in 709 ECR.
aws ecr describe-images --profile marketplace-account --region us-east-1 \
  --repository-name diagrid/catalyst-dapr --image-ids imageTag=1.17.5-catalyst.7-multi

# 4. Login + push.
aws ecr get-login-password --profile marketplace-account --region us-east-1 \
  | helm registry login --username AWS --password-stdin \
      709825985650.dkr.ecr.us-east-1.amazonaws.com

./publish.py \
  --git-tag v1.17.5-catalyst.7 \
  --catalyst-version 1.17.5-catalyst.7 \
  --image-tag 1.17.5-catalyst.7-multi \
  --registry 709825985650.dkr.ecr.us-east-1.amazonaws.com \
  --repo diagrid

# 5. Post-push verification.
helm pull oci://709825985650.dkr.ecr.us-east-1.amazonaws.com/diagrid/catalyst-dapr-chart \
  --version 1.17.5-catalyst.7 --untar --untardir /tmp/verify
helm template /tmp/verify/catalyst-dapr-chart | grep 'image:' | grep -v '709825985650'
# (the grep above MUST return empty)
```

## Dry-run

`--dry-run` runs every step EXCEPT the final `helm push`. The packaged
`.tgz` is preserved at
`/tmp/catalyst-dapr-chart-publish-<CHART_VERSION>-dist/catalyst-dapr-chart-<CHART_VERSION>.tgz`
so the operator can inspect before the real push.

```bash
./publish.py \
  --fork-src /tmp/dapr-dapr-v1.17.5-catalyst.7 \
  --catalyst-version 1.17.5-catalyst.7 \
  --image-tag 1.17.5-catalyst.7-multi \
  --registry 709825985650.dkr.ecr.us-east-1.amazonaws.com \
  --repo diagrid \
  --dry-run
```

## Failure recovery

- Partial push (chart packaged but push failed): re-run `publish.py`. ECR
  allows same-tag overwrites; runs are idempotent.
- Bad patch: re-run with the prior `N` to overwrite, or bump `N` and try
  again.
- Stale workdir from a previous run: `publish.py` always `rm -rf`'s
  `/tmp/catalyst-dapr-chart-publish-<CHART_VERSION>` at startup and on EXIT.
  Set `KEEP_WORKDIR=true` to retain the workdir for inspection on failure.

## Tests

Unit tests live in `tests/` and cover argument parsing, `patches.yaml` schema
validation, version string handling, patch application logic, and all seven
validation gates.

```bash
# Install deps (once):
make install-test-deps

# Run:
make test

# Lint:
make lint
```

Tests mock all subprocess calls (`git`, `helm`, `yq`, `make`) — no network
access or real chart source is required.

## One-time AMMP listing setup

This pipeline assumes `diagrid/catalyst-dapr-chart` has been registered as an
ECR repository on the AMMP container listing via `AddRepositories`. That step
is one-time per listing and is handled outside this script (manual
`AddRepositories` change-set against the AMMP container listing).

## What publish.py does NOT do

- Build the `catalyst-dapr` container image (separate fork CI).
- Submit AMMP AddDeliveryOptions change-sets (a separate publishing step
  targets the **catalyst** chart, not this one).
- Register repos with AMMP (one-time `AddRepositories`, outside).
- Auto-compute `N`. Operator supplies `--git-tag` and `--catalyst-version`
  explicitly.

## Where the chart lands in PR-51

The catalyst chart's AMMP overlay
(`charts/charts/catalyst/values-aws-marketplace.yaml`) references the
catalyst-dapr **image tag** at `agent.config.internal_dapr.image_tag`. The
catalyst-dapr **chart** itself is pulled by cra-agent at install time
according to `global.charts.daprChartName` plus cra-agent's own chart-version
default. So a chart-version bump here does not automatically require a
catalyst-chart overlay edit; only image-tag bumps do.
