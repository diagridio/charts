# Configuring Catalyst Gateway TLS

The Catalyst gateway terminates TLS for traffic entering Catalyst from your apps and from outside the cluster. This guide covers the supported ways to provision the gateway certificate — self-signed (dev), bring-your-own (production), and cert-manager — plus the values you need when the cert is signed by a private/internal CA.

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
