# Air-Gapped / Private Registry Installs

For air-gapped environments, mirror all Catalyst images and the Helm chart itself into your private registry, then point the chart at it via values.

For the full image list that the chart depends on, see the [Images reference](../../charts/catalyst/README.md#images).

## 1. Mirror Container Images

Use the provided script to mirror every image Catalyst needs, from the registries the released chart names. It renders the chart version you install with the values files you install it with, so an image or tag your values override is the one it copies, and reads the images the agent deploys after installation from the agent's config in that render. Where your values leave the Dapr control plane or the JWT key rotation image to the agent, it copies what the chart's annotations say the agent deploys. Without `--values` it renders the chart's defaults. It needs Helm. Released charts pin every Diagrid image by digest, so the mirror has to serve the same manifests as the source registry. The script uses `oras cp --recursive` when ORAS and jq are installed, which preserves digests and also copies each image's signature, provenance and SBOMs, and `crane copy` otherwise, which preserves digests but copies the image alone. A `docker pull` followed by `docker push` can re-encode layers and change digests, and a digest-pinned chart then fails to pull from the mirror.

```bash
./scripts/catalyst/mirror-images.sh my-registry.example.com \
  --chart oci://public.ecr.aws/diagrid/catalyst --chart-version <version> \
  --values catalyst-values.yaml \
  --charts-registry oci://my-registry.example.com/diagrid/catalyst
```

Pass `--values` once for each file you give `helm install`, in the same order. A values file that already sets `global.image.registry` to your mirror is fine: the script renders against Diagrid's registries to find where to copy from.

`--charts-registry` also copies Diagrid's Dapr chart, which the agent installs from `global.charts.registry` (step 2), at the version your values pin or, if they pin none, the one the chart records. Give it a path of its own: the Dapr chart and the Dapr image share a name and a tag.

Turn on in your values everything you plan to use before you mirror: an image a setting adds later, such as `mcp.enabled`, is copied only when the render names it. A chart released before those annotations lists the Dapr control plane and the JWT key rotation images under "Runtime Images" in its README, and the script reads them from there.

Install ORAS if you want to verify the mirrored images: see [Verify Diagrid's artifacts](https://docs.diagrid.io/operate/hosting/enterprise-self-hosted/verify-artifacts#check-a-mirrored-copy).

Then point the chart at your registry with
[`examples/private-registry.yaml`](../../charts/catalyst/examples/private-registry.yaml), which
the chart ships (`helm pull --untar` gives you a copy). It sets the image and chart registries,
the pull secrets for the images the agent deploys, and the registry for the Bitnami charts behind
the in-cluster PostgreSQL. The override changes only the registry part of each image reference;
the digest the chart pins stays the same, which is why the copy above has to preserve it.

## 2. Mirror the Helm Chart

Copy the chart with ORAS, which keeps its digest and its signature:

```bash
oras cp --recursive public.ecr.aws/diagrid/catalyst:<version> \
  my-registry.example.com/diagrid/catalyst/catalyst:<version>
```

This is the path `helm push catalyst-<version>.tgz oci://my-registry.example.com/diagrid/catalyst` would write. `helm pull` and `helm push` work too, but `helm push` gives the chart a new digest, which its signature does not cover.

The agent also pulls charts while it runs, such as the Dapr chart it installs, from
`global.charts.registry`. `global.charts` in
[`examples/private-registry.yaml`](../../charts/catalyst/examples/private-registry.yaml) sets
that registry and the secret holding its credentials.
