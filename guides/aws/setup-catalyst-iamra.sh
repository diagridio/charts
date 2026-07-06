#!/usr/bin/env bash
#
# setup-catalyst-iamra.sh
#
# Bootstraps the AWS side of Catalyst's IAM Roles Anywhere integration:
#   1. Resolves the App ID's SPIFFE ID, the project's Catalyst region, and that
#      region's trust (CA) endpoint via the `diagrid` CLI.
#   2. Registers the region's Diagrid CA as a Roles Anywhere Trust Anchor.
#   3. Creates an IAM role whose trust policy lets IAM Roles Anywhere assume it
#      ONLY for that App ID's exact SPIFFE ID (URI SAN).
#   4. Creates a Roles Anywhere profile pointing at that role.
#
# It STOPS after creating the profile. It does NOT create the Catalyst component
# — that command is printed at the end so you can wire it up by hand.
#
# Requirements: aws, jq, curl, and the diagrid CLI (logged in).

set -euo pipefail

# ---- defaults --------------------------------------------------------------
AWS_PROFILE=""        # optional; falls back to the ambient AWS env/credentials
REGION="us-east-1"    # AWS region for the trust anchor (not the Catalyst region)
PROJECT=""            # required
APPID=""              # required
SHOW_EXAMPLE=false    # print the end-to-end DynamoDB wiring example at the end

usage() {
  cat <<'EOF'
Usage: setup-catalyst-iamra.sh --project NAME --appid NAME [options]

Required:
  --project NAME      Catalyst project the App ID belongs to
  --appid NAME        Catalyst App ID to bind the IAM role to

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
    --appid)       APPID="$2"; shift 2 ;;
    --show-example) SHOW_EXAMPLE=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$PROJECT" ]] || { echo "error: --project is required" >&2; exit 2; }
[[ -n "$APPID" ]]   || { echo "error: --appid is required" >&2; exit 2; }

for bin in aws jq curl diagrid; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' not found on PATH" >&2; exit 1; }
done

# aws invocation: only pin --profile when the user asked for one, otherwise let
# the AWS CLI resolve credentials from the environment (AWS_PROFILE, default, etc).
AWS=(aws)
[[ -n "$AWS_PROFILE" ]] && AWS+=(--profile "$AWS_PROFILE")

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# ---- 1. resolve identifiers via diagrid ------------------------------------
echo "==> Resolving SPIFFE ID for App ID '${APPID}' in project '${PROJECT}'"
SPIFFE_ID="$(diagrid appid get "$APPID" --project "$PROJECT" -o json | jq -r '.status.spiffeId // empty')"
if [[ -z "$SPIFFE_ID" ]]; then
  echo "error: could not resolve a SPIFFE ID for App ID '${APPID}'." >&2
  echo "       Is it placed/ready? Try: diagrid appid get ${APPID} --project ${PROJECT}" >&2
  exit 1
fi
echo "    SPIFFE ID: ${SPIFFE_ID}"

echo "==> Resolving Catalyst region from project '${PROJECT}'"
CATALYST_REGION="$(diagrid project get "$PROJECT" -o json | jq -r '.spec.region // empty')"
[[ -n "$CATALYST_REGION" ]] || { echo "error: project '${PROJECT}' has no region in its spec" >&2; exit 1; }
echo "    Catalyst region: ${CATALYST_REGION}"

echo "==> Resolving trust endpoint from region '${CATALYST_REGION}'"
INGRESS="$(diagrid region get "$CATALYST_REGION" -o json | jq -r '.spec.ingress // empty')"
[[ -n "$INGRESS" ]] || { echo "error: region '${CATALYST_REGION}' has no ingress" >&2; exit 1; }

# Ingress is "https://*.<wildcard-domain>:<port>" — derive scheme/domain/port.
SCHEME="${INGRESS%%://*}"
HOSTPORT="${INGRESS#*://}"; HOSTPORT="${HOSTPORT%%/*}"
if [[ "$HOSTPORT" == *:* ]]; then
  HOST="${HOSTPORT%:*}"; PORT="${HOSTPORT##*:}"
else
  HOST="$HOSTPORT"; PORT=""
fi
WILDCARD_DOMAIN="${HOST#\*.}"
[[ -n "$PORT" ]] || { [[ "$SCHEME" == "https" ]] && PORT=443 || PORT=80; }

# Region CA (trust) endpoint, mirroring the control plane's well-known name.
CA_URL="${SCHEME}://trust.${WILDCARD_DOMAIN}:${PORT}"
TA_NAME="catalyst-${CATALYST_REGION}"
ROLE_NAME="catalyst-${CATALYST_REGION}-${PROJECT}-${APPID}"
echo "    CA endpoint: ${CA_URL}"
echo "    Trust anchor name: ${TA_NAME}"
echo "    IAM role name: ${ROLE_NAME}"

# ---- 2. trust anchor (idempotent by name) ----------------------------------
echo "==> Trust anchor '${TA_NAME}' in ${REGION}"
TA_ARN="$("${AWS[@]}" rolesanywhere list-trust-anchors --region "$REGION" \
  --query "trustAnchors[?name=='${TA_NAME}'].trustAnchorArn | [0]" --output text 2>/dev/null || true)"

if [[ -z "$TA_ARN" || "$TA_ARN" == "None" ]]; then
  echo "    Fetching CA bundle from ${CA_URL}"
  curl -fsS "$CA_URL" -o "$TMPDIR/diagrid-ca.pem"

  # AWS IAM Roles Anywhere only accepts RSA or ECDSA trust anchors. Fail fast
  # with a clear message instead of AWS's opaque "Unsupported key type" when the
  # region's CA is Ed25519 (private/dedicated regions) rather than RSA/ECDSA
  # (public SaaS, e.g. pem.trust.diagrid.io).
  if command -v openssl >/dev/null 2>&1; then
    KEY_ALG="$(openssl x509 -in "$TMPDIR/diagrid-ca.pem" -noout -text 2>/dev/null \
      | sed -n 's/.*Public Key Algorithm: //p' | head -1)"
    case "$KEY_ALG" in
      *rsaEncryption*|*id-ecPublicKey*) : ;;  # supported
      "") echo "    warning: could not parse CA key type; letting AWS validate" >&2 ;;
      *)
        echo "error: the region CA at ${CA_URL} uses key type '${KEY_ALG}'." >&2
        echo "       AWS IAM Roles Anywhere supports only RSA or ECDSA trust anchors," >&2
        echo "       so this region's Sentry PKI cannot be used with IAM Roles Anywhere." >&2
        exit 1 ;;
    esac
  fi

  jq -n --arg name "$TA_NAME" --rawfile pem "$TMPDIR/diagrid-ca.pem" \
    '{name:$name, source:{sourceType:"CERTIFICATE_BUNDLE", sourceData:{x509CertificateData:$pem}}, enabled:true}' \
    > "$TMPDIR/trust-anchor.json"
  TA_ARN="$("${AWS[@]}" rolesanywhere create-trust-anchor --region "$REGION" \
    --cli-input-json "file://$TMPDIR/trust-anchor.json" \
    --query 'trustAnchor.trustAnchorArn' --output text)"
  echo "    Created: ${TA_ARN}"
else
  echo "    Reusing existing: ${TA_ARN}"
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
    --description "Catalyst IAM Roles Anywhere role for App ID ${APPID}" \
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
  --scopes ${APPID} \\
  --wait
==============================================================================
EOF
