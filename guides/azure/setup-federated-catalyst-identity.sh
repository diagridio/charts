#!/bin/bash
set -euo pipefail

log() { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }

# assign_role PRINCIPAL_ID ROLE SCOPE DESCRIPTION — idempotently grant a role at a scope
assign_role() {
    local principal_id="$1" role="$2" scope="$3" what="$4"
    if [[ -n "$(az role assignment list \
        --assignee "${principal_id}" \
        --scope "${scope}" \
        --role "${role}" \
        --query "[0].id" --output tsv 2>/dev/null)" ]]; then
        log "Role '${role}' already assigned on ${what}; skipping."
    else
        log "Assigning role '${role}' to the identity on ${what}..."
        az role assignment create \
            --assignee-object-id "${principal_id}" \
            --assignee-principal-type ServicePrincipal \
            --role "${role}" \
            --scope "${scope}" \
            --output none
    fi
}

# assign_cosmos_data_role PRINCIPAL_ID ACCOUNT RESOURCE_GROUP — idempotently grant
# the Cosmos DB Built-in Data Contributor data-plane role on the account. Cosmos DB
# has its own data-plane RBAC system, separate from Azure resource-manager roles, so
# it can't go through assign_role.
assign_cosmos_data_role() {
    local principal_id="$1" account="$2" rg="$3"
    # Built-in "Cosmos DB Built-in Data Contributor" role definition id.
    local role_def_id="00000000-0000-0000-0000-000000000002"
    if [[ -n "$(az cosmosdb sql role assignment list \
        --account-name "${account}" \
        --resource-group "${rg}" \
        --query "[?principalId=='${principal_id}' && contains(roleDefinitionId, '${role_def_id}')].id | [0]" \
        --output tsv 2>/dev/null)" ]]; then
        log "Cosmos DB data role already assigned on '${account}'; skipping."
    else
        log "Assigning 'Cosmos DB Built-in Data Contributor' to the identity on Cosmos DB '${account}'..."
        az cosmosdb sql role assignment create \
            --account-name "${account}" \
            --resource-group "${rg}" \
            --role-definition-id "${role_def_id}" \
            --principal-id "${principal_id}" \
            --scope "/" \
            --output none
    fi
}

# Defaults (override with the flags below or matching env vars)
CATALYST_PROJECT="${CATALYST_PROJECT:-prj1}"
CATALYST_APP="${CATALYST_APP:-app1}"

# Display name of the Azure AD application (app registration) that backs the
# identity. One app registration per Catalyst project (defaults to
# "catalyst-<project>"), so each project gets its own Azure identity and its own
# scoped role assignments; every appid in the project gets its own federated
# credential(s) (below). Override to share or rename the app.
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-}"

# Optional: when set, grant the identity data-plane access to these resources.
# RESOURCE_GROUP is required only with --cosmosdb / --servicebus, whose lookups
# are resource-group scoped (Key Vault and storage resolve by name alone).
RESOURCE_GROUP="${RESOURCE_GROUP:-}"
CATALYST_KEYVAULT="${CATALYST_KEYVAULT:-}"
CATALYST_STORAGE_ACCOUNT="${CATALYST_STORAGE_ACCOUNT:-}"
CATALYST_COSMOSDB="${CATALYST_COSMOSDB:-}"
CATALYST_SERVICEBUS="${CATALYST_SERVICEBUS:-}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Sets up an Azure AD application (app registration) federated to a Catalyst
AppID via its SPIFFE workload identity. Instead of trusting an AKS cluster's
service-account OIDC, the federated credential trusts the Catalyst region's
OIDC issuer and the appid's SPIFFE ID — so any Catalyst sidecar presenting that
SPIFFE identity can exchange its token for an Azure AD token (audience
api://AzureADTokenExchange) and access the granted Azure resources.

The app registration is scoped to the project (one per project), and the SPIFFE
subject(s) are read straight from the appid's status (.status.spiffeIds, falling
back to .status.spiffeId); a sidecar may run on more than one region host, so a
credential is federated for each.

The OIDC issuer is resolved automatically from the project's region (via the
diagrid CLI), so it does not need to be supplied.

Options:
  --project NAME           Catalyst project name        (default: ${CATALYST_PROJECT})
  --app NAME               AppID name                   (default: ${CATALYST_APP})
  --app-display-name NAME  Azure AD app display name    (default: catalyst-<project>)
  --keyvault NAME          Grant 'Key Vault Secrets User' on this Key Vault             (optional)
  --storage-account NAME   Grant 'Storage Blob Data Contributor' on this account        (optional)
  --cosmosdb NAME          Grant 'Cosmos DB Built-in Data Contributor' on this account  (optional)
  --servicebus NAME        Grant 'Azure Service Bus Data Owner' on this namespace       (optional)
  --resource-group NAME    Azure resource group (required with --cosmosdb/--servicebus) (optional)
  -h, --help               Show this help and exit

Each option may also be supplied via an env var of the same name, e.g.:
  CATALYST_PROJECT=prj1 ./$(basename "$0")
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) CATALYST_PROJECT="$2"; shift 2 ;;
        --app) CATALYST_APP="$2"; shift 2 ;;
        --app-display-name) APP_DISPLAY_NAME="$2"; shift 2 ;;
        --keyvault) CATALYST_KEYVAULT="$2"; shift 2 ;;
        --storage-account) CATALYST_STORAGE_ACCOUNT="$2"; shift 2 ;;
        --cosmosdb) CATALYST_COSMOSDB="$2"; shift 2 ;;
        --servicebus) CATALYST_SERVICEBUS="$2"; shift 2 ;;
        --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# Scope the app registration to the project unless an explicit name was given.
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-catalyst-${CATALYST_PROJECT}}"

if [[ ( -n "${CATALYST_COSMOSDB}" || -n "${CATALYST_SERVICEBUS}" ) && -z "${RESOURCE_GROUP}" ]]; then
    echo "ERROR: --resource-group (or RESOURCE_GROUP) is required with --cosmosdb / --servicebus." >&2
    usage >&2
    exit 1
fi

# Resolve the appid's SPIFFE identities from the Diagrid control plane. The
# sidecar may run on more than one region host, each with its own SPIFFE ID
# (.status.spiffeIds); we federate a credential for every one. Fall back to the
# single .status.spiffeId for older control planes.
log "Resolving SPIFFE identities for appid '${CATALYST_APP}' in project '${CATALYST_PROJECT}'..."
APPID_YAML="$(diagrid appid get "${CATALYST_APP}" --project "${CATALYST_PROJECT}" --output yaml)"

SPIFFE_IDS=()
while IFS= read -r sid; do
    [[ -n "${sid}" && "${sid}" != "null" ]] && SPIFFE_IDS+=("${sid}")
done < <(printf '%s\n' "${APPID_YAML}" | yq '.status.spiffeIds // [] | .[]')

if [[ ${#SPIFFE_IDS[@]} -eq 0 ]]; then
    SINGLE_SPIFFE_ID="$(printf '%s\n' "${APPID_YAML}" | yq '.status.spiffeId')"
    if [[ -n "${SINGLE_SPIFFE_ID}" && "${SINGLE_SPIFFE_ID}" != "null" ]]; then
        SPIFFE_IDS=("${SINGLE_SPIFFE_ID}")
    fi
fi

if [[ ${#SPIFFE_IDS[@]} -eq 0 ]]; then
    echo "ERROR: appid '${CATALYST_APP}' in project '${CATALYST_PROJECT}' has no SPIFFE ID in its status yet." >&2
    exit 1
fi
log "Found ${#SPIFFE_IDS[@]} SPIFFE identity(ies):"
for sid in "${SPIFFE_IDS[@]}"; do log "  ${sid}"; done

# Resolve the region's OIDC issuer from the control plane: the project pins the
# region (.spec.region), and the region publishes its issuer (.status.endpoints.oidc).
REGION_ID="$(diagrid project get "${CATALYST_PROJECT}" --output yaml | yq '.spec.region')"
if [[ -z "${REGION_ID}" || "${REGION_ID}" == "null" ]]; then
    echo "ERROR: project '${CATALYST_PROJECT}' has no region assigned." >&2
    exit 1
fi
ISSUER="$(diagrid region get "${REGION_ID}" --output yaml | yq '.status.endpoints.oidc')"
if [[ -z "${ISSUER}" || "${ISSUER}" == "null" ]]; then
    echo "ERROR: region '${REGION_ID}' has no OIDC issuer (.status.endpoints.oidc) yet." >&2
    exit 1
fi
log "Region '${REGION_ID}' OIDC issuer: ${ISSUER}"

SUBSCRIPTION="$(az account show --query id --output tsv)"
TENANT_ID="$(az account show --query tenantId --output tsv)"
log "Using subscription: ${SUBSCRIPTION}"
log "Using tenant: ${TENANT_ID}"

# One app registration per Catalyst project, federated to each of the project's
# appid SPIFFE identities via its own federated credential(s) (below).
APP_ID="$(az ad app list \
    --display-name "${APP_DISPLAY_NAME}" \
    --query "[0].appId" \
    --output tsv)"
if [[ -n "${APP_ID}" ]]; then
    log "App registration '${APP_DISPLAY_NAME}' already exists; reusing it."
else
    log "Creating app registration '${APP_DISPLAY_NAME}'..."
    APP_ID="$(az ad app create \
        --display-name "${APP_DISPLAY_NAME}" \
        --query appId \
        --output tsv)"
fi
log "Application (client) ID: ${APP_ID}"

# Service principal for the app — required for the role assignments below.
SP_OBJECT_ID="$(az ad sp show --id "${APP_ID}" --query id --output tsv 2>/dev/null || true)"
if [[ -n "${SP_OBJECT_ID}" ]]; then
    log "Service principal already exists; reusing it."
else
    log "Creating service principal for app '${APP_ID}'..."
    SP_OBJECT_ID="$(az ad sp create --id "${APP_ID}" --query id --output tsv)"
fi
log "Service principal object ID: ${SP_OBJECT_ID}"

# Federated identity credential per SPIFFE ID — the (issuer + subject) trust
# mapping that lets the Catalyst identity exchange its token for an Azure AD token.
FIC_PARAMS="$(mktemp)"
trap 'rm -f "${FIC_PARAMS}"' EXIT
for SUBJECT in "${SPIFFE_IDS[@]}"; do
    # Derive a stable, unique credential name from the appid and the host portion
    # of the SPIFFE ID (the part that differs between region hosts). The project
    # is already implied by the per-project app registration.
    authority="${SUBJECT#spiffe://}"; authority="${authority%%/*}"
    host_label="${authority%%.*}"
    fic_name="${CATALYST_APP}-${host_label}"
    fic_name="$(printf '%s' "${fic_name}" | tr -c 'A-Za-z0-9_-' '-')"

    cat > "${FIC_PARAMS}" <<EOF
{
  "name": "${fic_name}",
  "issuer": "${ISSUER}",
  "subject": "${SUBJECT}",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF

    if az ad app federated-credential show \
        --id "${APP_ID}" \
        --federated-credential-id "${fic_name}" &>/dev/null; then
        log "Federated credential '${fic_name}' already exists; updating it."
        az ad app federated-credential update \
            --id "${APP_ID}" \
            --federated-credential-id "${fic_name}" \
            --parameters "@${FIC_PARAMS}" \
            --output none
    else
        log "Creating federated credential '${fic_name}' for subject '${SUBJECT}'..."
        az ad app federated-credential create \
            --id "${APP_ID}" \
            --parameters "@${FIC_PARAMS}" \
            --output none
    fi
done

# Optional role assignments — only run when the corresponding resource was supplied
if [[ -n "${CATALYST_KEYVAULT}" ]]; then
    log "Resolving Key Vault '${CATALYST_KEYVAULT}'..."
    KEYVAULT_SCOPE="$(az keyvault show --name "${CATALYST_KEYVAULT}" --query id --output tsv)"
    assign_role "${SP_OBJECT_ID}" "Key Vault Secrets User" "${KEYVAULT_SCOPE}" "Key Vault '${CATALYST_KEYVAULT}'"
fi

if [[ -n "${CATALYST_STORAGE_ACCOUNT}" ]]; then
    log "Resolving storage account '${CATALYST_STORAGE_ACCOUNT}'..."
    STORAGE_SCOPE="$(az storage account show --name "${CATALYST_STORAGE_ACCOUNT}" --query id --output tsv)"
    assign_role "${SP_OBJECT_ID}" "Storage Blob Data Contributor" "${STORAGE_SCOPE}" "storage account '${CATALYST_STORAGE_ACCOUNT}'"
fi

if [[ -n "${CATALYST_COSMOSDB}" ]]; then
    log "Resolving Cosmos DB account '${CATALYST_COSMOSDB}'..."
    assign_cosmos_data_role "${SP_OBJECT_ID}" "${CATALYST_COSMOSDB}" "${RESOURCE_GROUP}"
fi

if [[ -n "${CATALYST_SERVICEBUS}" ]]; then
    log "Resolving Service Bus namespace '${CATALYST_SERVICEBUS}'..."
    SERVICEBUS_SCOPE="$(az servicebus namespace show --name "${CATALYST_SERVICEBUS}" --resource-group "${RESOURCE_GROUP}" --query id --output tsv)"
    assign_role "${SP_OBJECT_ID}" "Azure Service Bus Data Owner" "${SERVICEBUS_SCOPE}" "Service Bus namespace '${CATALYST_SERVICEBUS}'"
fi

echo '--- Federated Catalyst Identity ready ---'
echo 'Configure your Azure component with the following workload-identity values:'
echo ''
echo "  azureClientId = ${APP_ID}"
echo "  azureTenantId = ${TENANT_ID}"
