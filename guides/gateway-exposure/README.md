# Exposing the Catalyst Gateway

The Catalyst gateway is the region's single entry point: every hostname under the region's wildcard domain, `*.<region-domain>`, reaches the region through it. This guide covers getting traffic to it: the Service type, a public or private address, the port, DNS, and the one rule anything in front of it must follow.

For the gateway's certificate, see the [Gateway TLS guide](../gateway-tls/README.md). For the chart values, see [Gateway Address](../../charts/catalyst/README.md#gateway-address) and [Gateway TLS](../../charts/catalyst/README.md#gateway-tls) in the chart README.

## The default: reachable only inside the cluster

The gateway is the `gateway-envoy` Service in the release namespace (`cra-agent` in these guides). The chart makes it a `ClusterIP`, with two ports:

| Port | Value | Serves |
|---|---|---|
| `8443` | `gateway.envoy.service.httpsPort` | TLS: your project endpoints, and the region's gRPC services passed through |
| `8080` | `gateway.envoy.service.port` | Plaintext HTTP |

So nothing outside the cluster can reach the region until you change the Service type.

## Who has to reach it

- **Your applications**, which call your project endpoints, such as `https://http-<project-id>.<region-domain>`.
- **The Diagrid console and CLI**, on the machine you use them from. The console reads app data from the region directly, through `management.<region-domain>`. If that machine cannot reach the gateway, for example because the address is internal, use the [Management API Tunnel](../../charts/catalyst/README.md#management-api-tunnel) instead.
- **The region itself.** The Dapr scheduler advertises each replica as `dapr-scheduler-server-<N>.<region-domain>`, so the region's own cluster must resolve the wildcard and reach the gateway's address.

## Layer 4 only

The gateway routes on the hostname in the TLS handshake (SNI). It terminates TLS for your project endpoints, but passes the region's gRPC services (`sentry.`, `xrs.`, `dapr-api.`, `dapr-placement.`, `dapr-scheduler.` and each `dapr-scheduler-server-<N>.`) through unchanged; they present their own certificates and speak gRPC, which needs HTTP/2. Clients check those certificates, Sentry's SPIFFE identity included, so no proxy can sit in the middle, not even one that re-encrypts with a certificate you trust.

So anything between clients and the gateway must forward TCP: no TLS termination, no HTTP/2 refusal, for any hostname under the region's wildcard.

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
- **No wildcards allowed.** Create one record per name instead: `management.`, `oidc.`, `sentry.`, `xrs.`, `dapr-api.`, `dapr-placement.`, `dapr-scheduler.` and each `dapr-scheduler-server-<N>.` (`0` to `2` by default), plus one per project endpoint you use, such as `http-<project-id>.`. You have to add the project records as projects are created.
- **A parent wildcard does not cover it.** A `*.<parent-domain>` record or certificate matches one label only, so it does not match `sentry.<region-domain>`. Create the region's record explicitly.

The gateway's certificate must cover `*.<region-domain>` as well. See the [Gateway TLS guide](../gateway-tls/README.md), or let Diagrid Cloud provide both the name and the certificate with a [Managed Domain](../../charts/catalyst/README.md#managed-domain).

## Check

From a machine on a network that has to reach the region, and again from a pod in the region's cluster:

```bash
openssl s_client -connect sentry.<region-domain>:443 -servername sentry.<region-domain> -alpn h2 </dev/null
```

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
