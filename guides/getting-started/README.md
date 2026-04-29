# Getting Started with Catalyst Enterprise Self-Hosted

This guide walks you through a first-time install of Catalyst Enterprise Self-Hosted: signing up for Diagrid Cloud, creating a region, retrieving a join token, and installing the Helm chart into your cluster.

For the full chart reference (every configurable value), see the [Catalyst chart README](../../charts/catalyst/README.md).

## Prerequisites

- Kubernetes 1.20+
- [Helm](https://helm.sh/) v3.12.0+
- [Diagrid CLI](https://docs.diagrid.io/catalyst/references/cli-reference/intro)
- [jq](https://stedolan.github.io/jq/)

## Step 1: Obtain a Join Token

Sign up or log in to [Diagrid Catalyst](https://catalyst.diagrid.io), then create a new `region` via the [Diagrid CLI](https://docs.diagrid.io/catalyst/references/cli-reference/intro):

```bash
diagrid login

export JOIN_TOKEN=$(diagrid region create <region-name> --ingress "https://<ingress-domain>" | jq -r .joinToken)
```

> **NOTE:** The join token can be regenerated before successfully completing the installation, but not after.

## Step 2: Install the Chart

```bash
helm install catalyst oci://public.ecr.aws/diagrid/catalyst \
     -n cra-agent \
     --create-namespace \
     -f catalyst-values.yaml \
     --set join_token="${JOIN_TOKEN}"
```

## Step 3: Verify the Installation

```bash
kubectl -n cra-agent wait --for=condition=ready pod --all --timeout=5m

# Verify the region is connected
diagrid region list
```

## Uninstall

```bash
helm uninstall catalyst -n cra-agent
```

> **WARNING:** The `region` resource is intended for a single installation. Once you uninstall Catalyst, the region is no longer valid. If you want to uninstall but allow re-installation, disable the cleanup hook:
>
> ```yaml
> cleanup:
>   enabled: false
> ```

## Next Steps

- [Catalyst chart reference](../../charts/catalyst/README.md) — all configurable Helm values
- Environment-specific install guides: [KinD](../kind/README.md) · [AKS](../azure/README.md) · [EKS](../aws/README.md)
- [Catalyst Documentation](https://docs.diagrid.io/catalyst)
