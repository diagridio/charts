### Diagrid Helm Charts
This repo contains the public Helm charts published by Diagrid.

## Catalyst
The Catalyst Helm Chart is available under `charts/catalyst`.

## Testing Catalyst

> this steps are currently targeting our test environment

- Get the [Diagrid CLI](https://docs.diagrid.io/catalyst/references/cli-reference/intro)

- Signup at [catalyst.diagrid.io](catalyst.dev.diagrid.io)

- Login to the environment
```
diagrid login --api https://api.dev.diagrid.io
```

- Create a region
```
diagrid region create my-region
```

- Copy the join token and install the catalyst helm chart
```
helm install catalyst ./charts/catalyst/ -n cra-agent --create-namespace -f environments/catalyst/dev-values.yaml --set agent.config.host.join_token=<your-join-token> 
```

- Monitor the deployment and verify your region successfully connects
```
diagrid region list
```
