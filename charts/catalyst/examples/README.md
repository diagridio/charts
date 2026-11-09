# Example values

Starting points for the common ways to install Catalyst. Each file holds only
what its scenario changes from the chart defaults, with a comment on every
setting. Copy one, replace the placeholders, and pass it with `-f`.

| File | Use it for |
|---|---|
| [`kind.yaml`](kind.yaml) | Evaluation on a local kind cluster, as in the [KinD guide](../../../guides/kind/README.md) |
| [`../values-production.yaml`](../values-production.yaml) | Production: resources, autoscaling and log levels. The base for every scenario below |
| [`external-postgresql.yaml`](external-postgresql.yaml) | A PostgreSQL you run, such as Amazon RDS, Cloud SQL or Azure Database for PostgreSQL |
| [`private-registry.yaml`](private-registry.yaml) | Air-gapped clusters, or pulling only from your own registry |
| [`aks-workload-identity.yaml`](aks-workload-identity.yaml) | AKS: app secrets encrypted with an Azure Key Vault key, reached with Workload ID |
| [`eks-irsa.yaml`](eks-irsa.yaml) | EKS: app secrets encrypted with an AWS KMS key, reached with IRSA |

## Using them

The files ship inside the chart, so the copy you use always matches the chart
version you install:

```bash
helm pull oci://public.ecr.aws/diagrid/catalyst --version <version> --untar
```

Helm applies values files left to right, and a later file wins key by key.
`kind.yaml` stands alone. Every other example goes on top of
`values-production.yaml`, which turns off the in-cluster PostgreSQL, so put
`external-postgresql.yaml` next, then your scenarios, then your own file:

```bash
helm install catalyst oci://public.ecr.aws/diagrid/catalyst --version <version> \
  -n cra-agent --create-namespace \
  -f catalyst/values-production.yaml \
  -f catalyst/examples/external-postgresql.yaml \
  -f catalyst/examples/eks-irsa.yaml \
  -f my-values.yaml \
  --set join_token="${JOIN_TOKEN}"
```

Every example is linted and rendered against the chart in exactly that order
on each change to either (`make helm-examples`), so a setting the chart renames
cannot leave an example behind.
