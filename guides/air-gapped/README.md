# Air-Gapped / Private Registry Installs

For air-gapped environments, mirror all Catalyst images and the Helm chart itself into your private registry, then point the chart at it via values.

For the full image list that the chart depends on, see the [Images reference](../../charts/catalyst/README.md#images).

## 1. Mirror Container Images

Use the provided script to mirror every image Catalyst needs. Released charts pin every Diagrid image by digest, so the mirror has to serve the same manifests as the source registry: the script uses `crane copy` when crane is installed, which preserves digests. A `docker pull` followed by `docker push` can re-encode layers and change digests, and a digest-pinned chart then fails to pull from the mirror.

```bash
./scripts/catalyst/mirror-images.sh my-registry.example.com \
  --catalyst-version 0.469.0 \
  --dapr-version 1.16.2 \
  --internal-dapr-version 1.16.2-catalyst.1 \
  --envoy-version distroless-v1.33.0 \
  --piko-version v0.8.2 \
  --otel-version 0.112.0
```

Then point the chart at your registry. The override changes only the registry part of each image reference; the digest the chart pins stays the same, which is why the copy above has to preserve it:

```yaml
global:
  image:
    registry: my-registry.example.com
```

If you use OpenTelemetry addons, override their image repositories too:

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

## 2. Mirror the Helm Chart

```bash
helm pull oci://public.ecr.aws/diagrid/catalyst --version <version>
helm push catalyst-<version>.tgz oci://my-registry.example.com/diagrid/catalyst
```

Configure authentication in `values.yaml`:

```yaml
global:
  charts:
    registry: "oci://my-registry.example.com/diagrid/catalyst"
    username: "my-username"
    password: "my-password"
    # Or use existingSecret, clientCert, clientKey, customCA
```
