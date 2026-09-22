# The key encryption key for the PostgreSQL secrets provider.
#
# Catalyst envelope-encrypts every secret it stores: each secret is sealed with
# a data encryption key, and that key is sealed with this one. Every region in a
# region group must resolve the SAME key, because the sealed rows replicate
# between them — a region holding a different key reads the rows and cannot
# decrypt them.
#
# A multi-region KMS key is how that is true without a key being copied
# anywhere. The first region creates the primary; the second creates a replica
# of it, which is the same key identity with its own ARN in its own region. Each
# region encrypts and decrypts against the copy next to it.
#
# Off by default: a single region has nothing to share a key with, and the
# secrets provider's local KEK is the simpler choice there.

resource "aws_kms_key" "catalyst_kek" {
  count = var.kek_kms_enabled && var.kek_kms_replica_source_key_arn == "" ? 1 : 0

  description = "Catalyst secrets provider key encryption key for ${var.cluster_name}"

  # What makes it replicable into the group's other region.
  multi_region = true

  # Left off deliberately. The two regions have to agree on this key, and
  # turning rotation on is a decision about that agreement rather than about
  # one region — make it for the group, not here.
  enable_key_rotation = false

  deletion_window_in_days = 30

  tags = {
    Name = "${var.cluster_name}-kek"
  }
}

resource "aws_kms_replica_key" "catalyst_kek" {
  count = var.kek_kms_enabled && var.kek_kms_replica_source_key_arn != "" ? 1 : 0

  description     = "Catalyst secrets provider key encryption key for ${var.cluster_name}"
  primary_key_arn = var.kek_kms_replica_source_key_arn

  deletion_window_in_days = 30

  tags = {
    Name = "${var.cluster_name}-kek"
  }
}

locals {
  kek_key_arn = var.kek_kms_replica_source_key_arn != "" ? one(aws_kms_replica_key.catalyst_kek[*].arn) : one(aws_kms_key.catalyst_kek[*].arn)
  kek_key_id  = var.kek_kms_replica_source_key_arn != "" ? one(aws_kms_replica_key.catalyst_kek[*].key_id) : one(aws_kms_key.catalyst_kek[*].key_id)
}

# The agent and the management service reach KMS with the pod's own identity:
# the secrets provider is given no access key, so the AWS SDK falls through to
# the credential chain, which on EKS is the service account's role.
resource "aws_iam_role" "catalyst_kek" {
  count = var.kek_kms_enabled ? 1 : 0

  name = "${var.cluster_name}-${var.aws_region}-catalyst-kek-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com",
            "${module.eks.oidc_provider}:sub" = var.kek_kms_service_account_subjects
          },
        }
      }
    ]
  })
}

# Encrypt and Decrypt and nothing else: those are the two calls the secrets
# provider makes, and it makes them on this one key.
resource "aws_iam_policy" "catalyst_kek" {
  count = var.kek_kms_enabled ? 1 : 0

  name        = "${var.cluster_name}-${var.aws_region}-catalyst-kek-policy"
  description = "Wrap and unwrap Catalyst data encryption keys with the region group's KEK"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
        ]
        Resource = local.kek_key_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "catalyst_kek" {
  count = var.kek_kms_enabled ? 1 : 0

  role       = aws_iam_role.catalyst_kek[0].name
  policy_arn = aws_iam_policy.catalyst_kek[0].arn
}

output "kek_kms_key_id" {
  description = "Key id of the region's KEK. A multi-region key and its replicas share one key id, so this value is IDENTICAL in both regions of a group — and it is the value both must configure as `aws_kms_key_id`, because the control plane compares what each region was configured with rather than what it resolves to."
  value       = local.kek_key_id
}

output "kek_kms_key_arn" {
  description = "ARN of this region's copy of the KEK. Region-local. Feed the first region's value to the second region's `kek_kms_replica_source_key_arn`."
  value       = local.kek_key_arn
}

output "kek_kms_role_arn" {
  description = "ARN of the role the Catalyst agent and management service assume to use the KEK. Goes on `global.serviceAccount.annotations` as `eks.amazonaws.com/role-arn`."
  value       = try(aws_iam_role.catalyst_kek[0].arn, null)
}
