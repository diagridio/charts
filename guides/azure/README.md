# Azure

There are two Azure guides in this directory. Which one you need depends on
what you want to build:

| You want | Use | Docs |
|---|---|---|
| A private AKS demo behind a firewall | The **installation guide**: `install.sh`, `setup.sh`, `setup-federated-catalyst-identity.sh` and `setup-user-managed-catalyst-identity.sh` | [Installation guides](https://docs.diagrid.io/catalyst/enterprise-self-hosted/installation-guide) |
| One production region, or two regions in a region group | The **reference terraform**: `terraform/`, `Makefile` and `failover.sh` | [Azure multi-region deployment guide](https://docs.diagrid.io/operate/hosting/enterprise-self-hosted/azure-multi-region-deployment) |

If you only need one production region, use the reference terraform and set up
one region. You can add the second region and the group later.

You can't add a region built with the installation guide to a region group. Its
gateway uses an internal load balancer, and Azure's cross-region load balancer
only works with public ones.

To switch which region takes writes, see
[Failing a self-managed region group over on Azure](../../../docs/content/runbooks/catalyst-region-group-failover-azure.md).

## Testing these guides against staging

Both guides point at production Diagrid Cloud, because that's what customers
use. To test against staging, you need a few extra settings that the guides
don't cover. The [AWS README](../aws/README.md#testing-these-guides-against-staging)
lists them.
