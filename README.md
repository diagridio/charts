### Diagrid Helm Charts
This repo contains the public Helm charts published by Diagrid.

> ⚠️ This repository is under active development and some of these instructions may be aspirational or stale.

## Catalyst

Diagrid Catalyst is a collection of API-based programming patterns for messaging, data, and workflow that is fully compliant with the Dapr open source project.

For more information on how Catalyst can turbo charge your development, please visit the [docs](https://docs.diagrid.io/catalyst).

### Prerequisites
- [Diagrid CLI](https://docs.diagrid.io/catalyst/references/cli-reference/intro)
- [Diagrid Account](https://catalyst.diagrid.io)
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [Helm](https://helm.sh/)
- A Kubernetes cluster

### Installation
> NOTE: this steps are currently targeting our test environment

To install the Catalyst Helm Chart you must first create a `Region`.

```
diagrid login
export JOIN_TOKEN=$(diagrid region create myregion | jq .joinToken)
```

Once you have created a `Region`, you can install the Catalyst Helm Chart.

From our public OCI registry:
```
aws ecr-public get-login-password \
     --region us-east-1 | helm registry login \
     --username AWS \
     --password-stdin public.ecr.aws

helm install catalyst oci://public.ecr.aws/diagrid/catalyst -n cra-agent --create-namespace -f environments/catalyst/dev-values.yaml --set "agent.config.host.join_token=${JOIN_TOKEN}" --version 0.0.0-edge
```

From this repository:
```
helm install catalyst ./charts/catalyst/ -n cra-agent --create-namespace -f environments/catalyst/dev-values.yaml --set "agent.config.host.join_token=${JOIN_TOKEN}" 
```
