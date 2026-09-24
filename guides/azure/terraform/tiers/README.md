# Region size tiers

Per-tier variable files for this guide's terraform, one per Catalyst region
size. Applying one gives you the same AKS node pool and PostgreSQL Flexible
Server that Diagrid provisions for a managed region of that size — the figures
the Catalyst UI shows on the self-managed region create form.

Each file sets only the size: node VM size, node pool min and desired count,
and the PostgreSQL SKU and storage. Availability posture, backups, networking
and peering keep this guide's own defaults — those are operator decisions, not
part of the size.

Two variables the AWS guide's tier files set are deliberately absent here:

- `node_max_capacity`, the autoscaler ceiling. It comes from the manifest's
  provisioning knobs, which the Azure rows do not carry, because Diagrid does
  not provision Azure regions. This guide's own default carries the headroom.
- `postgresql_max_allocated_storage`. Flexible Server grows its own storage
  (`postgresql_auto_grow_enabled`) and has no ceiling to configure.

A tier file is therefore a *partial* set of variables, meant to layer on top of
your own `terraform.tfvars` (subscription, location, cluster name, VNet CIDRs,
peering, bastion). `-var-file` is repeatable, so pass both:

```bash
cd terraform
terraform plan  -var-file=terraform.tfvars -var-file=tiers/medium.tfvars
terraform apply -var-file=terraform.tfvars -var-file=tiers/medium.tfvars
```

The guide's `make plan` / `make apply` take a single `TF_VAR_FILE`, so
`make apply TF_VAR_FILE=terraform/tiers/medium.tfvars` would **replace** your
variables rather than add to them. Use the two-file `terraform` invocation
above, or copy the tier values into your own `terraform.tfvars`.

**Both regions of a region group must be the same tier.** The passive region's
PostgreSQL is a read replica, and Azure will not build one smaller than the
server it follows.

**The `.tfvars` files are generated — do not edit them.** They come from
`pkg/regiontier/tiers.yaml`, the manifest that also sizes the regions Diagrid
provisions. Change that file and run `make gen-region-tiers` from the repo
root; `make check-region-tiers` and the unit tests fail if they drift.
