# Configuring Catalyst Gateway TLS

The Catalyst gateway terminates TLS for HTTP traffic entering Catalyst from your apps and from outside the cluster. It passes the region's gRPC control plane services (Sentry, management, the Dapr API, placement and scheduler) through without terminating TLS; they present their own certificates, so the certificate in this guide is not used for them. The [Gateway TLS](../../charts/catalyst/README.md#gateway-tls) section of the chart README lists those hostnames. This guide covers the supported ways to provision the gateway certificate — self-signed (dev), bring-your-own (production), and cert-manager — plus the values you need when the cert is signed by a [private/internal CA](#private-or-self-signed-ca).

For the underlying chart values, see the [`gateway.tls`](../../charts/catalyst/README.md#gateway-tls) reference.

## How the chart consumes the certificate

The gateway loads its serving cert from a Kubernetes `kubernetes.io/tls` secret. There are two ways to supply it:

| Option | Helm values | When the secret is created |
|--------|-------------|----------------------------|
| Reference an existing secret | `gateway.tls.existingSecret` | You create the secret (BYO, cert-manager, etc.) |
| Provide cert/key inline | `gateway.tls.cert`, `gateway.tls.key` | The chart creates `<release>-gateway-tls` for you |

The Envoy data plane reads `tls.crt` / `tls.key` from that secret by default. You can override the file names via `gateway.tls.certificates.certFile` / `keyFile` if your secret uses different keys.

## Option 1: Self-signed certificate (dev/test only)

For local clusters and demos, generate a self-signed wildcard cert and pass it inline. The [kind guide](../kind/README.md#step-4-create-self-signed-certificate-) walks through this end-to-end using CFSSL, then installs the chart with:

```bash
helm install catalyst oci://public.ecr.aws/diagrid/catalyst \
  -n cra-agent --create-namespace \
  -f catalyst-values.yaml \
  --set-file gateway.tls.cert=server.pem \
  --set-file gateway.tls.key=server-key.pem
```

Without `--version` this installs whichever version the registry reports as
highest, which is fine for a dev cluster but is not a guarantee of what you
get — pin `--version <version>` anywhere you need a reproducible install. See
[chart channels](../getting-started/README.md#chart-channels).

with the values:

```yaml
gateway:
  tls:
    enabled: true
```

Don't use self-signed certs in production — clients will need to trust the CA out of band, and there is no automatic rotation.

## Option 2: Bring your own certificate (BYO)

Use this when you already have a certificate from your corporate CA, an internal PKI, or a public CA (e.g. DigiCert, Let's Encrypt issued elsewhere).

1. Create a TLS secret in the Catalyst release namespace:

   ```bash
   kubectl -n cra-agent create secret tls my-gateway-tls \
     --cert=path/to/server.crt \
     --key=path/to/server.key
   ```

2. Point the chart at it:

   ```yaml
   gateway:
     tls:
       enabled: true
       existingSecret: my-gateway-tls
   ```

If your secret stores the cert/key under non-default keys, also set `gateway.tls.certificates`:

```yaml
gateway:
  tls:
    enabled: true
    existingSecret: my-gateway-tls
    certificates:
      certFile: server.crt
      keyFile: server.key
```

You are responsible for renewing the secret before the certificate expires. See [Rotation](#certificate-rotation).

## Option 3: cert-manager

For automated issuance and renewal, let [cert-manager](https://cert-manager.io/) provision the secret.

1. Install cert-manager (skip if already installed):

   ```bash
   helm repo add jetstack https://charts.jetstack.io
   helm install cert-manager jetstack/cert-manager \
     --namespace cert-manager --create-namespace \
     --set installCRDs=true
   ```

2. Define an `Issuer` (or `ClusterIssuer`) appropriate for your environment — ACME, internal CA, Vault, etc. Example using a private CA already loaded into a cert-manager `Secret`:

   ```yaml
   apiVersion: cert-manager.io/v1
   kind: Issuer
   metadata:
     name: internal-ca-issuer
     namespace: cra-agent
   spec:
     ca:
       secretName: internal-ca
   ```

3. Request a `Certificate` whose `secretName` matches what you'll pass to the chart:

   ```yaml
   apiVersion: cert-manager.io/v1
   kind: Certificate
   metadata:
     name: catalyst-gateway
     namespace: cra-agent
   spec:
     secretName: catalyst-gateway-tls
     dnsNames:
       - gateway.catalyst.example.com
     issuerRef:
       name: internal-ca-issuer
       kind: Issuer
     duration: 2160h     # 90 days
     renewBefore: 360h   # renew 15 days before expiry
   ```

4. Reference the secret in your Catalyst values:

   ```yaml
   gateway:
     tls:
       enabled: true
       existingSecret: catalyst-gateway-tls
   ```

cert-manager rewrites the secret in place when the certificate renews. The gateway picks up the new material on its next pod restart — see [Rotation](#certificate-rotation).

## Private or self-signed CA

When no public CA signed the gateway certificate, three things have to know the CA as well as the gateway does:

- **The secret** carries the CA under a third key, `ca.crt`, next to `tls.crt` and `tls.key`. Only an `existingSecret` can do that: the secret the chart creates from inline `cert`/`key` has no CA key.
- **The agent** is told which key holds it, with `gateway.tls.certificates.caFile`. The chart copies that into the agent's `agent.config.host.ingress.tls.secret.ca_file`, which is the same setting: set either one, and if you set both, the agent value wins. When it starts, the agent reads that key from the gateway secret and includes the CA in the configuration it hands every sidecar. The secret name comes from `gateway.tls.existingSecret`, so you only set the key.
- **Your applications** trust the CA, because they call your project endpoints (`https://http-<project-id>.<region-domain>`) through the gateway. See [Application trust](#application-trust).

For the sidecars' own outbound connections to anything signed by this CA, also add it through [Sidecar Outbound TLS Trust](../../charts/catalyst/README.md#sidecar-outbound-tls-trust).

### With cert-manager and a self-signed CA

cert-manager creates the CA, an issuer that signs with it, and one wildcard certificate for the region. Replace `myregion.example.com` with your region's domain. Install cert-manager first, as in [Option 3](#option-3-cert-manager).

```yaml
# 1. Bootstraps the CA. Signs nothing else.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
---
# 2. The CA certificate and key, in the secret catalyst-ca.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: catalyst-ca
  namespace: cra-agent
spec:
  isCA: true
  commonName: catalyst-ca
  secretName: catalyst-ca
  duration: 87600h    # 10 years
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned
    kind: ClusterIssuer
---
# 3. An issuer that signs with that CA.
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: catalyst-ca
  namespace: cra-agent
spec:
  ca:
    secretName: catalyst-ca
---
# 4. The gateway certificate: one wildcard for the whole region.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: catalyst-gateway
  namespace: cra-agent
spec:
  secretName: catalyst-gateway-tls
  dnsNames:
    - "*.myregion.example.com"
  issuerRef:
    name: catalyst-ca
    kind: Issuer
  duration: 2160h     # 90 days
  renewBefore: 360h   # renew 15 days before expiry
```

A CA issuer writes `ca.crt` into the secret it issues, so `catalyst-gateway-tls` holds all three keys. Point the chart at it:

```yaml
gateway:
  tls:
    enabled: true
    existingSecret: catalyst-gateway-tls
    certificates:
      caFile: ca.crt
```

Export the CA for your applications and for the [check](#check-it) below:

```bash
kubectl -n cra-agent get secret catalyst-gateway-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
```

### With a certificate from your corporate CA

`kubectl create secret tls`, as in [Option 2](#option-2-bring-your-own-certificate-byo), takes only a certificate and a key. Create the secret as a generic one of type `kubernetes.io/tls` instead, so it can carry `ca.crt`:

```bash
kubectl -n cra-agent create secret generic my-gateway-tls \
  --type=kubernetes.io/tls \
  --from-file=tls.crt=path/to/server.crt \
  --from-file=tls.key=path/to/server.key \
  --from-file=ca.crt=path/to/ca.crt
```

`server.crt` is the wildcard certificate for `*.<region-domain>`, followed by any intermediate certificates; `ca.crt` is the root. The values are the same as above, with `existingSecret: my-gateway-tls`.

### Application trust

Every application that calls a project endpoint needs the CA, or each call fails certificate verification (a typical message is `self signed certificate in certificate chain`). Mount `ca.crt` into the application pod, for example from a ConfigMap:

```bash
kubectl -n <app-namespace> create configmap catalyst-ca --from-file=ca.crt=ca.crt
```

then point the runtime's trust at it:

- **Go, and OpenSSL-based runtimes such as Python:** `SSL_CERT_FILE`. It replaces the system bundle rather than adding to it, so point it at a file holding the system roots followed by `ca.crt` if the application also calls public endpoints.
- **gRPC clients built on gRPC C-core** (Python, among others): `GRPC_DEFAULT_SSL_ROOTS_FILE_PATH`, which gRPC reads instead of `SSL_CERT_FILE`.
- **Node.js:** `NODE_EXTRA_CA_CERTS`, which adds to the built-in roots.
- **Anything else:** your language's trust store setting (a Java truststore, for example), or bake the CA into the image's system trust store.

### Check it

From somewhere that resolves the region's domain, ask the gateway for a project endpoint and verify it against the CA:

```bash
openssl s_client -connect http-<project-id>.<region-domain>:443 \
  -servername http-<project-id>.<region-domain> \
  -CAfile ca.crt </dev/null
```

A good answer ends with `Verify return code: 0 (ok)`. Run it again without `-CAfile`: it should then fail verification, which confirms the CA, not a public root, is what makes it pass.

Then confirm the agent loaded the CA. It reads it only at start, so restart it after setting `caFile` or after the CA changes:

```bash
kubectl -n cra-agent rollout restart deploy/agent
kubectl -n cra-agent logs deploy/agent | grep 'ingress TLS'
```

You should see `loaded ingress TLS CA certificate from secret cra-agent/<secret> (key: ca.crt)`. Instead:

- `failed to read ingress TLS secret` means the agent could not read the secret named in `existingSecret` from its namespace.
- No line at all means neither `caFile` nor `ca_file` is set, or the secret has no key by that name. Check with `kubectl -n cra-agent get secret <secret> -o jsonpath='{.data}'`.

## Certificate rotation

- **Inline (`cert`/`key`)** — re-run `helm upgrade` with new `--set-file` values. The chart's secret carries a checksum annotation, so the gateway pods roll automatically.
- **`existingSecret` (BYO)** — update the secret (`kubectl create secret tls ... --dry-run=client -o yaml | kubectl apply -f -`), then restart the gateway: `kubectl -n cra-agent rollout restart deploy/gateway-envoy`.
- **cert-manager** — renewal is automatic. Trigger a rollout after renewal so Envoy reloads: `kubectl -n cra-agent rollout restart deploy/gateway-envoy`.

## Troubleshooting

- **Pods not picking up a new cert:** the gateway loads TLS material at start. Roll the deployment after the secret changes (`rollout restart deploy/gateway-envoy`).
- **`gateway.tls.enabled: true` but no secret found:** either set `existingSecret` to an existing TLS secret in the release namespace, or provide `cert`/`key` inline so the chart creates one.
- **Verify what the gateway loaded:**

  ```bash
  kubectl -n cra-agent get secret <secret-name> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -dates
  ```

See the [cert-manager documentation](https://cert-manager.io/docs/) for issuer-specific setup.
