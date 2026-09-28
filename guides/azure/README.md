# Azure

Both Azure guides build their regions from the reference terraform in this
directory: `terraform/`, `Makefile` and `failover.sh`.

| You want | Docs |
|---|---|
| One region | [Azure deployment guide](https://docs.diagrid.io/operate/hosting/enterprise-self-hosted/azure-installation-guide) |
| Two regions in a region group | [Azure multi-region deployment guide](https://docs.diagrid.io/operate/hosting/enterprise-self-hosted/azure-multi-region-deployment) |

A region that already holds projects can't join a region group, and group
members need settings the single-region guide leaves at their defaults: the
PostgreSQL secrets provider, a shared key encryption key, and
`region_group_member = true`. If you plan to build a group, follow the
multi-region guide from the start.

`setup-user-managed-catalyst-identity.sh` and
`setup-federated-catalyst-identity.sh` set up Azure identities for Catalyst
apps. Both guides use them.

To switch which region takes writes, see
[Failing a self-managed region group over on Azure](../../../docs/content/runbooks/catalyst-region-group-failover-azure.md).

## Testing these guides against staging

Both guides point at production Diagrid Cloud, because that's what customers
use. To test against staging, you need a few extra settings that the guides
don't cover. The [AWS README](../aws/README.md#testing-these-guides-against-staging)
lists them.
