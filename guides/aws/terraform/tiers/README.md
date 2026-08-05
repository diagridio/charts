# Region size tiers

Per-tier variable files for this guide's terraform, one per Catalyst region
size. Applying one gives you the same EKS node group and RDS PostgreSQL
instance that Diagrid provisions for a managed region of that size — the
figures the Catalyst UI shows on the self-managed region create form.

Each file sets only the size: node instance type, node group min/desired/max,
and the PostgreSQL instance class and storage. Availability posture, backups,
networking and peering keep this guide's own defaults — those are operator
decisions, not part of the size.

A tier file is therefore a *partial* set of variables, meant to layer on top of
your own `terraform.tfvars` (region, cluster name, VPC CIDR, peering, bastion).
`-var-file` is repeatable, so pass both:

```bash
cd terraform
terraform plan  -var-file=terraform.tfvars -var-file=tiers/medium.tfvars
terraform apply -var-file=terraform.tfvars -var-file=tiers/medium.tfvars
```

The guide's `make plan` / `make apply` take a single `TF_VAR_FILE`, so
`make apply TF_VAR_FILE=terraform/tiers/medium.tfvars` would **replace** your
variables rather than add to them. Use the two-file `terraform` invocation
above, or copy the tier values into your own `terraform.tfvars`.

**The `.tfvars` files are generated — do not edit them.** They come from
`pkg/regiontier/tiers.yaml`, the manifest that also sizes the regions Diagrid
provisions. Change that file and run `make gen-region-tiers` from the repo
root; `make check-region-tiers` and the unit tests fail if they drift.
