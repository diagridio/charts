# Air-Gapped / Private Registry Installs

For air-gapped environments, mirror all Catalyst images and the Helm chart itself into your private registry, then point the chart at it via values.

For the full image list that the chart depends on, see the [Images reference](../../charts/catalyst/README.md#images).

## 1. Mirror Container Images

Use the provided script to mirror every image Catalyst needs, from the registries the released chart names. Released charts pin every Diagrid image by digest, so the mirror has to serve the same manifests as the source registry. The script uses `oras cp --recursive` when ORAS and jq are installed, which preserves digests and also copies each image's signature, provenance and SBOMs, and `crane copy` otherwise, which preserves digests but copies the image alone. A `docker pull` followed by `docker push` can re-encode layers and change digests, and a digest-pinned chart then fails to pull from the mirror.

```bash
./scripts/catalyst/mirror-images.sh my-registry.example.com \
  --catalyst-version 0.469.0 \
  --dapr-version 1.16.2 \
  --internal-dapr-version 1.16.2-catalyst.1 \
  --envoy-version distroless-v1.33.0 \
  --piko-version v0.8.2 \
  --otel-version 0.112.0
```

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
