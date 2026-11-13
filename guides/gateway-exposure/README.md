# Exposing the Catalyst Gateway

The Catalyst gateway is the region's single entry point: every hostname under the region's wildcard domain, `*.<region-domain>`, reaches the region through it, or the one hostname of a region served on [one hostname](#one-hostname-for-all-projects). This guide covers getting traffic to it: the Service type, a public or private address, the port, DNS, and the one rule anything in front of it must follow.

For the gateway's certificate, see the [Gateway TLS guide](../gateway-tls/README.md). For the chart values, see [Gateway Address](../../charts/catalyst/README.md#gateway-address) and [Gateway TLS](../../charts/catalyst/README.md#gateway-tls) in the chart README.

## The default: reachable only inside the cluster

The gateway is the `gateway-envoy` Service in the release namespace (`cra-agent` in these guides). The chart makes it a `ClusterIP`, with two ports:

| Port | Value | Serves |
|---|---|---|
| `8443` | `gateway.envoy.service.httpsPort` | TLS: your project endpoints, and the region's gRPC services passed through |
| `8080` | `gateway.envoy.service.port` | Plaintext HTTP |

So nothing outside the cluster can reach the region until you change the Service type.

## Who has to reach it

- **Your applications**, which call your project endpoints, such as `https://http-<project-id>.<region-domain>`, or the region's hostname in a region served on [one hostname](#one-hostname-for-all-projects).
- **The Diagrid console and CLI**, on the machine you use them from. The console reads app data from the region directly, through `management.<region-domain>`, or `/diagrid/management` on a region's one hostname. If that machine cannot reach the gateway, for example because the address is internal, use the [Management API Tunnel](../../charts/catalyst/README.md#management-api-tunnel) instead.
- **App IDs outside the region's cluster**, external App IDs and `diagrid dev` app tunnels, which reach the region's Dapr services through the gateway. The region's own sidecars reach those services inside the cluster, by cluster DNS, so they never go through the gateway.

## Layer 4 only

The gateway routes on the hostname in the TLS handshake (SNI). It terminates TLS for your project endpoints, but passes the region's gRPC services (`sentry.`, `xrs.`, `dapr-api.`, `dapr-placement.`, `dapr-scheduler.` and each `dapr-scheduler-server-<N>.`) through unchanged; they present their own certificates and speak gRPC, which needs HTTP/2. Clients check those certificates, Sentry's SPIFFE identity included, so no proxy can sit in the middle, not even one that re-encrypts with a certificate you trust.

So anything between clients and the gateway must forward TCP: no TLS termination, no HTTP/2 refusal, for any hostname under the region's wildcard. A region served on [one hostname](#one-hostname-for-all-projects) passes the same services through on that hostname, so the rule applies to it just the same.

| Cloud | Works | Breaks it |
|---|---|---|
| AWS | Network Load Balancer with a TCP listener | Application Load Balancer, an NLB TLS listener (the `service.beta.kubernetes.io/aws-load-balancer-ssl-cert` annotation), CloudFront, AWS WAF (which needs an ALB or CloudFront) |
| Azure | Azure Load Balancer, which AKS builds for a `LoadBalancer` Service | Application Gateway, with or without AGIC; Front Door |
| GCP | External or internal passthrough Network Load Balancer | An Application Load Balancer from a GKE `Ingress` or `Gateway`, Cloud Armor WAF rules, Cloud CDN |
| Any | A TCP load balancer, or `NodePort` behind one | A TLS-inspecting firewall or proxy (Zscaler, Palo Alto Networks, Netskope and the like) on the path |

When the rule is broken, sidecars and the region's services fail to connect, and their logs show `remote error: tls: no application protocol` (a proxy refusing HTTP/2, TLS alert 120) or a certificate error saying the certificate presented for `sentry.<region-domain>` is not Sentry's (a proxy presenting its own). Exempt the region's wildcard from TLS inspection, the same as the outbound mTLS endpoints in [Networking](../../charts/catalyst/README.md#networking).

## Choose the address

Set the Service type to `LoadBalancer`. The agent then reads the load balancer's address from the Service, reports it to the control plane, and follows it if the load balancer is rebuilt:

```yaml
gateway:
  envoy:
    service:
      type: LoadBalancer
```

Whether that address is public or private, and whether it is fixed, is decided by your cloud's annotations on the Service. Put them under `gateway.envoy.service.annotations`. Do not use `gateway.envoy.podAnnotations` for this: the chart copies those onto the Service as well, but also onto every gateway pod.

The chart does not set `spec.loadBalancerIP` or `spec.loadBalancerSourceRanges` on the Service, so use the annotations below for a fixed address, and your cloud's security groups or firewall rules to restrict who can connect.

### AWS

With the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) (or EKS Auto Mode), an internal NLB:

```yaml
gateway:
  envoy:
    service:
      type: LoadBalancer
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: external
        service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
        service.beta.kubernetes.io/aws-load-balancer-scheme: internal   # or internet-facing
```

An NLB gets a DNS name, not an IP, so point DNS at it with a `CNAME` or a Route 53 alias. For fixed addresses, add `service.beta.kubernetes.io/aws-load-balancer-private-ipv4-addresses` (internal) or `service.beta.kubernetes.io/aws-load-balancer-eip-allocations` (internet-facing), one per subnet.

### Azure

AKS builds a public address by default. For a private address on your virtual network:

```yaml
gateway:
  envoy:
    service:
      type: LoadBalancer
      annotations:
        service.beta.kubernetes.io/azure-load-balancer-internal: "true"
        service.beta.kubernetes.io/azure-load-balancer-internal-subnet: snet-ingress   # optional
        service.beta.kubernetes.io/azure-load-balancer-ipv4: 10.240.0.100              # optional, a free IP in that subnet
```

For a public IP you already own, use `service.beta.kubernetes.io/azure-pip-name: <public-ip-name>` and, when it lives in another resource group, `service.beta.kubernetes.io/azure-load-balancer-resource-group: <resource-group>`. The cluster's identity needs Network Contributor on that resource group or subnet.

### GCP

GKE builds an external passthrough Network Load Balancer by default. For an internal one:

```yaml
gateway:
  envoy:
    service:
      type: LoadBalancer
      annotations:
        networking.gke.io/load-balancer-type: Internal
        networking.gke.io/internal-load-balancer-allow-global-access: "true"   # optional, clients in other regions
```

For a fixed address, reserve one (`gcloud compute addresses create`, with `--subnet` for an internal one) and name it in `networking.gke.io/load-balancer-ip-addresses`.

### Your own cluster

With MetalLB or kube-vip, `LoadBalancer` works as above; MetalLB takes a fixed address from `metallb.io/loadBalancerIPs` (`metallb.universe.tf/loadBalancerIPs` on versions before 0.14).

With no load balancer integration, use `NodePort` and put your own TCP load balancer in front of the nodes:

```yaml
gateway:
  envoy:
    service:
      type: NodePort
      httpsNodePort: 30443
      nodePort: 30080
agent:
  config:
    host:
      ingress:
        ip_addr: 203.0.113.10   # your load balancer's address
        port: 443               # the port your load balancer listens on
```

The agent cannot read an address from a `NodePort` Service, so set `ip_addr` as above. Configure the load balancer for TCP passthrough, as in [Layer 4 only](#layer-4-only), for example `mode tcp` in HAProxy or a `stream` block in nginx, never an `http` one.

## Match the port

The agent reports the Service's `https` port, `8443` by default, and clients connect to the port in the region's ingress. The two must agree. Either:

- serve on 443, so the ingress needs no port:

  ```yaml
  gateway:
    envoy:
      service:
        httpsPort: 443   # httpsTargetPort stays 8443
  ```

  ```bash
  diagrid region create <region-name> --ingress "https://*.<region-domain>"
  ```

- or keep 8443 and put it in the ingress:

  ```bash
  diagrid region create <region-name> --ingress "https://*.<region-domain>:8443"
  ```

With a fixed `agent.config.host.ingress.ip_addr`, the agent reports `agent.config.host.ingress.port` instead, which is `443` by default. Set it to the port your load balancer listens on.

## DNS

Create one wildcard record for the region, `*.<region-domain>`, pointing at the gateway's address. Get the address once the chart is installed:

```bash
kubectl get svc -n cra-agent gateway-envoy -o jsonpath='{.status.loadBalancer.ingress[0]}'
```

The output holds an `ip`, for an `A` record, or a `hostname` (AWS), for a `CNAME`. It is empty while the Service is a `ClusterIP`.

- **Private address.** The record only has to resolve on the networks that reach the region, so a private DNS zone is enough. Remember the region's own cluster is one of them.
- **No wildcards allowed.** Serve the region on one hostname, which needs one record and one certificate: [One hostname for all projects](#one-hostname-for-all-projects).
- **A parent wildcard does not cover it.** A `*.<parent-domain>` record or certificate matches one label only, so it does not match `sentry.<region-domain>`. Create the region's record explicitly.

The gateway's certificate must cover `*.<region-domain>` as well, or only the hostname in a region served on [one hostname](#one-hostname-for-all-projects). See the [Gateway TLS guide](../gateway-tls/README.md), or let Diagrid Cloud provide both the name and the certificate with a [Managed Domain](../../charts/catalyst/README.md#managed-domain).

## One hostname for all projects

A region normally needs a wildcard DNS record and a wildcard certificate, because each project and each of the region's services has a hostname of its own under `*.<region-domain>`. If your policy forbids wildcard records, or certificates come through a ticket, a self-hosted region can be served on one hostname instead, such as `catalyst-api.mycompany.com`. That hostname serves the whole region, not only its projects.

Choose this when you create the region, and give the hostname as the ingress:

- the CLI: `diagrid region create <region-name> --shared-project-endpoint --ingress https://catalyst-api.mycompany.com`, and the same flags on `diagrid region deploy` when it creates the region;
- the API: `spec.sharedProjectEndpoint: true` with `spec.ingress: https://catalyst-api.mycompany.com`;
- the console: **Serve the region on one hostname** in the region's form, then the hostname in the box below it.

The ingress is one full hostname, with an optional port, such as `https://catalyst-api.mycompany.com:8443`. The control plane refuses a wildcard in this mode, and refuses the mode together with a [Managed Domain](../../charts/catalyst/README.md#managed-domain) or on a region Diagrid hosts. `http://` works as it does for a wildcard ingress, and is not advised for production.

Every cluster of the region must run a Catalyst version that serves this mode. The control plane refuses to turn it on while an older cluster is connected, and refuses an older cluster that tries to join a region that has it on. `status.supportsSharedProjectEndpoint` is `true` when every cluster is new enough.

### What the hostname serves

The gateway serves all of these on the hostname and its one port:

- **Project HTTP and gRPC APIs**, at the root. The App ID's API token, in the `dapr-api-token` header, picks the project and the App ID. A request with `content-type: application/grpc` goes to the App ID's gRPC API and anything else to its HTTP API. A missing or unknown token gets HTTP 401, or gRPC status `UNAUTHENTICATED`. App ID path restrictions apply, and Temporal API calls (`authorization: Bearer <token>`) work too.
- **The region's own HTTP services**, under `/diagrid/`: the management API at `/diagrid/management`, the trust bundle at `/diagrid/trust`, OIDC discovery at `/diagrid/oidc/`, and app tunnels at `/diagrid/tunnels`. These paths match only requests without a `dapr-api-token`, so an app's own path under `/diagrid/` still reaches the app. In a region group, the writability check at `/diagrid/region/writable` answers on the hostname too.
- **Sentry, xrs and the Dapr services**, passed through unchanged as in [Layer 4 only](#layer-4-only). Clients connect to the hostname, but send the service's own name, such as `sentry.catalyst-api.mycompany.com`, in the TLS handshake, and the gateway routes on that name. So those names need no certificate.

The control plane hands out the matching addresses: `https://<host>` (with the port, if the ingress has one) as every project's HTTP and gRPC endpoint, and `https://<host>/diagrid/management` as the region's management endpoint.

### Records and certificate

<!-- `diagrid region deploy` prints the same records (tools/cli/cmd/cloudruntime/regions/deploy_shared_endpoint.go); change both together. -->

Create one DNS record for the hostname, pointing at the gateway's address, and one certificate for it. See the [Gateway TLS guide](../gateway-tls/README.md) for installing the certificate. [Layer 4 only](#layer-4-only) applies to the hostname as it does to a wildcard.

Some clients still look up a passthrough service's name in DNS rather than connecting to the hostname. For them, add DNS records only, at the same address and with no certificate:

| Records | Needed for |
|---|---|
| `sentry.<host>` | `diagrid dev` and `diagrid listen` from a CLI older than the release that added this mode |
| `xrs.<host>`, `dapr-api.<host>`, `dapr-placement.<host>`, `dapr-scheduler.<host>`, and `dapr-scheduler-server-<N>.<host>` for each scheduler replica (`0` to `2` by default) | App IDs that run outside the region's cluster, until a Dapr release lets them connect to the hostname |

App IDs in the region's own cluster need none of them: they reach these services inside the cluster.

### Switching an existing region

Turning the mode on changes the region's domain to the new hostname, so every name under the old wildcard stops being served at once, including the project hostnames running apps use. To switch:

1. Create the DNS record and install the certificate for the new hostname, at the gateway's current address.
2. Run `diagrid region update <region-name> --shared-project-endpoint --ingress https://<host>`.
3. Point apps at the new endpoint: re-run `diagrid dev`, or set `DAPR_HTTP_ENDPOINT` and `DAPR_GRPC_ENDPOINT` to `https://<host>`, with the port if the ingress has one. External App IDs need their bootstrap configuration again.

Turning it off is the same in reverse, with a wildcard `--ingress`. Running apps lose their endpoint in both directions until they pick up the new one.

Then check the hostname, with an App's token:

```bash
curl -i -H "dapr-api-token: <the App's API token>" https://<host>/v1.0/healthz
```

A `2xx` answer means the record, the certificate and the route all work. A `401` means the gateway serves the hostname but matched no App ID to the token.

## Check

From a machine on a network that has to reach the region, and again from a pod in the region's cluster:

```bash
openssl s_client -connect sentry.<region-domain>:443 -servername sentry.<region-domain> -alpn h2 </dev/null
```

In a region served on [one hostname](#one-hostname-for-all-projects), connect to the hostname and keep Sentry's name for the handshake: `-connect <host>:443 -servername sentry.<host>`.

Use `:8443` if that is your port. A good answer shows `ALPN protocol: h2` and Sentry's own certificate, with a `spiffe://` URI in its subject alternative names.

| The check shows | Meaning | What to do |
|---|---|---|
| `No ALPN negotiated`, or `SSL alert number 120` | Something in front of the gateway terminates TLS or refuses HTTP/2 | Make the path TCP only: [Layer 4 only](#layer-4-only) |
| your wildcard certificate, or a load balancer's or corporate CA's | A proxy presents its own certificate in place of Sentry's | The same, or exempt the region from TLS inspection |
| an `errno` line, or nothing at all | The name does not resolve, or nothing answers on that port | Check the record, the Service type and [the port](#match-the-port) |

Then check a project endpoint, which the gateway terminates with its own certificate:

```bash
curl -v https://http-<project-id>.<region-domain>/
```

A TLS error here, with the Sentry check passing, is the gateway certificate; see the Gateway TLS guide's [Troubleshooting](../gateway-tls/README.md#troubleshooting).
