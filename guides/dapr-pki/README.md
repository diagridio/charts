# Configuring Dapr PKI with cert-manager

By default, Dapr Sentry generates a self-signed root CA. For production, integrate with your own PKI by providing an issuer CA and trust anchors. This guide uses [cert-manager](https://cert-manager.io/) and [trust-manager](https://cert-manager.io/docs/trust/trust-manager/) to provision the certificates.

For the chart values that point Catalyst at your PKI, see the [`agent.config.internal_dapr.pki`](../../charts/catalyst/README.md#dapr-pki) reference.

## 1. Install cert-manager and trust-manager

```bash
# Install cert-manager
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.12.0 \
  --set installCRDs=true

# Install trust-manager
helm upgrade trust-manager oci://quay.io/jetstack/charts/trust-manager \
  --install \
  --namespace cert-manager
```

## 2. Create a self-signed CA and Dapr trust bundle

```bash
cat <<EOF > cert-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: internal-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: internal-ca
  secretName: internal-ca
  privateKey:
    algorithm: ECDSA
  issuerRef:
    name: selfsigned
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: internal-ca-issuer
  namespace: cert-manager
spec:
  ca:
    secretName: internal-ca
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: dapr-trust-bundle
  namespace: cert-manager
spec:
  commonName: ""
  uris:
    - "spiffe://prj-root.trust.diagrid.io/ns/root-dapr-system/dapr-sentry"
  isCA: true
  usages:
    - digital signature
    - key encipherment
    - cert sign
    - crl sign
  privateKey:
    algorithm: ECDSA
    size: 256
  duration: 8760h   # 1 year
  renewBefore: 720h  # renew 30 days before
  secretName: dapr-trust-bundle
  issuerRef:
    name: internal-ca-issuer
    kind: Issuer
---
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: dapr-trust-bundle
spec:
  sources:
  - secret:
      name: dapr-trust-bundle
      key: ca.crt
  target:
    configMap:
      key: ca.crt
    namespaceSelector:
      matchLabels:
        name: cert-manager
EOF
```

```bash
kubectl apply -f cert-issuer.yaml
```

## 3. Wire the values into the Catalyst chart

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

See the [cert-manager documentation](https://cert-manager.io/docs/) for additional detail.
