# AWS

The AWS guide can be found under the [installation guides on our documentation](https://docs.diagrid.io/catalyst/enterprise-self-hosted/installation-guide).

The two-region variant is the [AWS multi-region deployment
guide](https://docs.diagrid.io/operate/hosting/enterprise-self-hosted/aws-multi-region-deployment),
and the runbook for moving the writer between members is
[Failing a self-managed region group over](../../../docs/content/runbooks/catalyst-region-group-failover.md).

## Testing these guides against staging

Both guides target production Diagrid Cloud, which is what a customer uses.
Nothing in them mentions the control plane the agent talks to, because for a
customer there is only one.

Testing against staging therefore needs overrides the guides do not give. Join
a region with a staging join token and no overrides and the install succeeds,
then the agent crash-loops with

```
error joining region: error verifying token jwt.Parse: failed to parse token:
jwt.VerifyCompact: signature verification failed for HS256: invalid HMAC signature
```

which reads like a bad or expired token and is actually the right token against
the wrong control plane — the chart defaults `global.control_plane_url`,
`global.control_plane_http_url` and `global.sentry.*` to production.

Add this to the values file for a staging region, alongside everything the guide
gives (the values come from
[`deploy/config/catalyst-dataplane/staging/catalyst-dataplane.yaml`](../../../deploy/config/catalyst-dataplane/staging/catalyst-dataplane.yaml),
which is the source of truth if they ever change):

```yaml
global:
  control_plane_namespace: controlplane
  control_plane_url: catalyst-cloud.staging.diagrid.dev:443
  control_plane_http_url: https://api.staging.diagrid.dev
  sentry:
    remote_endpoint: sentry.staging.diagrid.dev:443
    remote_namespace: controlplane
    trust_anchors_endpoint: https://trust.staging.diagrid.dev
```
