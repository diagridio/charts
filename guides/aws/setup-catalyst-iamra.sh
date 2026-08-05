#!/usr/bin/env bash
#
# setup-catalyst-iamra.sh
#
# Bootstraps the AWS side of Catalyst's IAM Roles Anywhere integration:
#   1. Resolves the app's SPIFFE ID and the project's Catalyst region via the
#      `diagrid` CLI.
#   2. Registers the CA that signs the app's X.509 SVID as a Roles Anywhere
#      Trust Anchor.
#   3. Creates an IAM role whose trust policy lets IAM Roles Anywhere assume it
#      ONLY for that app's exact SPIFFE ID (URI SAN).
#   4. Creates a Roles Anywhere profile pointing at that role.
#
# This is for self-hosted (private) regions only. Their sidecars present the
# identity issued by the in-region (data plane) Dapr Sentry, so the trust anchor
# is the region's own CA — read straight off the Region resource
# (`.status.trustAnchors`), with no call to the region's gateway, which may not
# be reachable from here at all.
#
# It STOPS after creating the profile. It does NOT create the Catalyst component
# — that command is printed at the end so you can wire it up by hand.
#
# Requirements: aws, jq, and the diagrid CLI (logged in).

set -euo pipefail

# ---- defaults --------------------------------------------------------------
AWS_PROFILE=""        # optional; falls back to the ambient AWS env/credentials
REGION="us-east-1"    # AWS region for the trust anchor (not the Catalyst region)
PROJECT=""            # required
APP=""                # required
SHOW_EXAMPLE=false    # print the end-to-end DynamoDB wiring example at the end

usage() {
  cat <<'EOF'
Usage: setup-catalyst-iamra.sh --project NAME --app NAME [options]

Required:
  --project NAME      Catalyst project the app belongs to
  --app NAME          Catalyst app to bind the IAM role to

Options:
  --aws-profile NAME  AWS CLI profile (default: ambient AWS env/credentials)
  --region REGION     AWS region for the trust anchor (default: us-east-1)
  --show-example      Print an end-to-end AWS DynamoDB wiring example (default: false)
  -h, --help          Show this help
EOF
}

# ---- arg parsing -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --aws-profile) AWS_PROFILE="$2"; shift 2 ;;
    --region)      REGION="$2"; shift 2 ;;
    --project)     PROJECT="$2"; shift 2 ;;
    --app|--appid) APP="$2"; shift 2 ;;  # --appid kept as a compatible alias
    --show-example) SHOW_EXAMPLE=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$PROJECT" ]] || { echo "error: --project is required" >&2; exit 2; }
[[ -n "$APP" ]]     || { echo "error: --app is required" >&2; exit 2; }

for bin in aws jq diagrid; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' not found on PATH" >&2; exit 1; }
done

# aws invocation: only pin --profile when the user asked for one, otherwise let
# the AWS CLI resolve credentials from the environment (AWS_PROFILE, default, etc).
AWS=(aws)
[[ -n "$AWS_PROFILE" ]] && AWS+=(--profile "$AWS_PROFILE")

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# ---- 1. resolve identifiers via diagrid ------------------------------------
echo "==> Resolving SPIFFE ID for app '${APP}' in project '${PROJECT}'"
# An App is a projection of a backing App ID, which is what carries the SPIFFE
# ID. `diagrid app get` embeds it under status.appIds.
SPIFFE_ID="$(diagrid app get "$APP" --project "$PROJECT" -o json \
  | jq -r '.status.appIds[0].status.spiffeId // empty')"
if [[ -z "$SPIFFE_ID" ]]; then
  echo "error: could not resolve a SPIFFE ID for app '${APP}'." >&2
  echo "       Is it placed/ready? Try: diagrid app get ${APP} --project ${PROJECT}" >&2
  exit 1
fi
echo "    SPIFFE ID: ${SPIFFE_ID}"

echo "==> Resolving Catalyst region from project '${PROJECT}'"
CATALYST_REGION="$(diagrid project get "$PROJECT" -o json | jq -r '.spec.region // empty')"
[[ -n "$CATALYST_REGION" ]] || { echo "error: project '${PROJECT}' has no region in its spec" >&2; exit 1; }
echo "    Catalyst region: ${CATALYST_REGION}"

echo "==> Reading the region CA from region '${CATALYST_REGION}'"
REGION_JSON="$(diagrid region get "$CATALYST_REGION" -o json)"
REGION_TYPE="$(jq -r '.spec.type // empty' <<<"$REGION_JSON")"
[[ -n "$REGION_TYPE" ]] || { echo "error: region '${CATALYST_REGION}' has no type in its spec" >&2; exit 1; }

# Self-hosted regions are private, which is all this guide covers. A dedicated
# region is private under the hood and the flow below would work unchanged — its
# sidecars use the same in-region Dapr Sentry CA — but Diagrid operates those.
# Only the public SaaS region signs app identities with a different CA (the
# control plane Sentry's), where this trust anchor would not validate them.
if [[ "$REGION_TYPE" != "private" ]]; then
  echo "error: region '${CATALYST_REGION}' is of type '${REGION_TYPE}'." >&2
  echo "       This script covers self-hosted (private) regions only." >&2
  exit 1
fi

# The region host submits its Dapr Sentry CA bundle when it joins and the control
# plane publishes it back inline on the Region status, so read it from there
# rather than fetching the region gateway's trust endpoint — a private region's
# ingress is often not reachable from where this runs.
CA_PEM="$TMPDIR/diagrid-ca.pem"
jq -r '.status.trustAnchors // empty' <<<"$REGION_JSON" > "$CA_PEM"
if [[ ! -s "$CA_PEM" ]]; then
  echo "error: region '${CATALYST_REGION}' publishes no .status.trustAnchors." >&2
  echo "       Only regions that joined with a CA carry it. Check the region host" >&2
  echo "       has finished joining: diagrid region get ${CATALYST_REGION}" >&2
  exit 1
fi

TA_NAME="catalyst-${CATALYST_REGION}"
ROLE_NAME="catalyst-${CATALYST_REGION}-${PROJECT}-${APP}"
echo "    CA source: .status.trustAnchors (in-region Dapr Sentry CA)"
echo "    Trust anchor name: ${TA_NAME}"
echo "    IAM role name: ${ROLE_NAME}"

# AWS IAM Roles Anywhere only accepts RSA or ECDSA trust anchors. Fail fast with
# a clear message instead of AWS's opaque "Unsupported key type": Dapr Sentry's
# built-in self-signed CA is Ed25519, so the region has to be given an ECDSA
# Dapr CA before its identities can be used with Roles Anywhere.
if command -v openssl >/dev/null 2>&1; then
  # `openssl x509` reads only the first certificate, and .status.trustAnchors is a
  # bundle that may carry more than one root, so split it and check every
  # certificate — AWS validates the whole bundle.
  awk -v d="$TMPDIR" '/-----BEGIN CERTIFICATE-----/{n++} n>0{print > (d "/ca-split-" n ".pem")}' "$CA_PEM"
  for cert in "$TMPDIR"/ca-split-*.pem; do
    [[ -e "$cert" ]] || { echo "    warning: no certificate found in the CA bundle; letting AWS validate" >&2; break; }
    KEY_ALG="$(openssl x509 -in "$cert" -noout -text 2>/dev/null \
      | sed -n 's/.*Public Key Algorithm: //p' | head -1)"
    case "$KEY_ALG" in
      *rsaEncryption*|*id-ecPublicKey*) : ;;  # supported
      "") echo "    warning: could not parse a CA key type; letting AWS validate" >&2 ;;
      *)
        echo "error: a certificate in the region CA bundle uses key type '${KEY_ALG}'." >&2
        echo "       AWS IAM Roles Anywhere supports only RSA or ECDSA trust anchors," >&2
        echo "       and Dapr Sentry's default self-signed CA is Ed25519. Give the" >&2
        echo "       region an ECDSA Dapr CA and re-run — deploy it with" >&2
        echo "         diagrid region deploy ... --enable-cert-manager-pki" >&2
        echo "       or follow charts/guides/dapr-pki/README.md." >&2
        exit 1 ;;
    esac
  done
fi

# ---- 2. trust anchor (idempotent by name) ----------------------------------
echo "==> Trust anchor '${TA_NAME}' in ${REGION}"
TA_ID="$("${AWS[@]}" rolesanywhere list-trust-anchors --region "$REGION" \
  --query "trustAnchors[?name=='${TA_NAME}'].trustAnchorId | [0]" --output text 2>/dev/null || true)"

jq -n --arg name "$TA_NAME" --rawfile pem "$CA_PEM" \
  '{name:$name, source:{sourceType:"CERTIFICATE_BUNDLE", sourceData:{x509CertificateData:$pem}}, enabled:true}' \
  > "$TMPDIR/trust-anchor.json"

if [[ -z "$TA_ID" || "$TA_ID" == "None" ]]; then
  TA_ARN="$("${AWS[@]}" rolesanywhere create-trust-anchor --region "$REGION" \
    --cli-input-json "file://$TMPDIR/trust-anchor.json" \
    --query 'trustAnchor.trustAnchorArn' --output text)"
  echo "    Created: ${TA_ARN}"
else
  # The anchor is now a customer-owned CA that rotates independently of Diagrid,
  # so reuse-by-name is not enough: refresh the bundle when it has drifted,
  # otherwise sessions fail after a Dapr CA rotation with no visible cause.
  EXISTING_TA="$("${AWS[@]}" rolesanywhere get-trust-anchor --region "$REGION" \
    --trust-anchor-id "$TA_ID" --output json)"
  EXISTING_PEM="$(jq -r '.trustAnchor.source.sourceData.x509CertificateData // empty' <<<"$EXISTING_TA")"
  TA_ARN="$(jq -r '.trustAnchor.trustAnchorArn' <<<"$EXISTING_TA")"
  if [[ "$(tr -d '[:space:]' <<<"$EXISTING_PEM")" == "$(tr -d '[:space:]' < "$CA_PEM")" ]]; then
    echo "    Reusing existing: ${TA_ARN}"
  else
    echo "    CA bundle changed — updating existing anchor"
    "${AWS[@]}" rolesanywhere update-trust-anchor --region "$REGION" \
      --trust-anchor-id "$TA_ID" \
      --source "$(jq -c '.source' "$TMPDIR/trust-anchor.json")" >/dev/null
    echo "    Updated: ${TA_ARN}"
  fi
fi

# ---- 3. IAM role + trust policy (idempotent by name) -----------------------
echo "==> IAM role '${ROLE_NAME}'"
jq -n --arg ta "$TA_ARN" --arg spiffe "$SPIFFE_ID" '{
  Version: "2012-10-17",
  Statement: [{
    Effect: "Allow",
    Principal: { Service: "rolesanywhere.amazonaws.com" },
    Action: ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"],
    Condition: {
      ArnEquals: { "aws:SourceArn": $ta },
      StringEquals: { "aws:PrincipalTag/x509SAN/URI": $spiffe }
    }
  }]
}' > "$TMPDIR/role-trust.json"

if "${AWS[@]}" iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "    Role exists — updating trust policy"
  "${AWS[@]}" iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "file://$TMPDIR/role-trust.json"
else
  "${AWS[@]}" iam create-role \
    --role-name "$ROLE_NAME" \
    --description "Catalyst IAM Roles Anywhere role for app ${APP}" \
    --assume-role-policy-document "file://$TMPDIR/role-trust.json" >/dev/null
  echo "    Created role"
fi

ROLE_ARN="$("${AWS[@]}" iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)"

# ---- 4. Roles Anywhere profile (idempotent by name) ------------------------
echo "==> Roles Anywhere profile '${ROLE_NAME}'"
PROFILE_ARN="$("${AWS[@]}" rolesanywhere list-profiles --region "$REGION" \
  --query "profiles[?name=='${ROLE_NAME}'].profileArn | [0]" --output text 2>/dev/null || true)"

if [[ -z "$PROFILE_ARN" || "$PROFILE_ARN" == "None" ]]; then
  PROFILE_ARN="$("${AWS[@]}" rolesanywhere create-profile --region "$REGION" \
    --name "$ROLE_NAME" \
    --role-arns "$ROLE_ARN" \
    --enabled \
    --query 'profile.profileArn' --output text)"
  echo "    Created: ${PROFILE_ARN}"
else
  echo "    Reusing existing: ${PROFILE_ARN}"
fi

# ---- done: stop here, print the remaining (manual) step --------------------
PROFILE_FLAG=""
[[ -n "$AWS_PROFILE" ]] && PROFILE_FLAG="--profile ${AWS_PROFILE} "
ACCOUNT_ID="${ROLE_ARN#arn:aws:iam::}"; ACCOUNT_ID="${ACCOUNT_ID%%:*}"

cat <<EOF

==============================================================================
Done. Created the trust anchor, IAM role, and profile (no Catalyst component).

  Trust anchor : ${TA_ARN}
  IAM role     : ${ROLE_ARN}
  Profile      : ${PROFILE_ARN}
  SPIFFE match : ${SPIFFE_ID}

  NOTE: the role has no permissions policy yet, so it grants no access.
EOF

if [[ "$SHOW_EXAMPLE" != true ]]; then
  echo "  Re-run with --show-example for an end-to-end AWS DynamoDB wiring example."
  echo "=============================================================================="
  exit 0
fi

cat <<EOF

Example: wire the role up to an AWS DynamoDB state store.

# 1) Create the DynamoDB table (partition key must be named 'key', type String)
aws ${PROFILE_FLAG}dynamodb create-table --region ${REGION} \\
  --table-name Contracts \\
  --attribute-definitions AttributeName=key,AttributeType=S \\
  --key-schema AttributeName=key,KeyType=HASH \\
  --billing-mode PAY_PER_REQUEST

# 2) Attach a read/write DynamoDB permissions policy to the role
#    (replace the table name 'Contracts' below to match your table)
cat > perms.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:BatchGetItem",
        "dynamodb:Query",
        "dynamodb:Scan",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:BatchWriteItem",
        "dynamodb:TransactGetItems",
        "dynamodb:TransactWriteItems"
      ],
      "Resource": [
        "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/Contracts",
        "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/Contracts/index/*"
      ]
    }
  ]
}
JSON

aws ${PROFILE_FLAG}iam put-role-policy --role-name ${ROLE_NAME} \\
  --policy-name catalyst-access --policy-document file://perms.json

# 3) Create the Catalyst component (AWS DynamoDB)
diagrid component create dynamodb \\
  --type state.aws.dynamodb \\
  --project ${PROJECT} \\
  --metadata region=${REGION} \\
  --metadata table=Contracts \\
  --metadata assumeRoleArn=${ROLE_ARN} \\
  --metadata trustAnchorArn=${TA_ARN} \\
  --metadata trustProfileArn=${PROFILE_ARN} \\
  --scopes ${APP} \\
  --wait
==============================================================================
EOF
