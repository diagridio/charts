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
RESOURCE_GROUP="${RESOURCE_GROUP:-rg1}"
LOCATION="${LOCATION:-westeurope}"
CLUSTER_NAME="${CLUSTER_NAME:-catalyst-cluster}"

CATALYST_PROJECT="${CATALYST_PROJECT:-prj1}"
CATALYST_APP="${CATALYST_APP:-app1}"
# Note: the sidecar service account namespace/name are always derived from the
# project/appid UIDs (resolved below) — they are not configurable.

# Optional: when set, grant the identity data-plane access to these resources
CATALYST_KEYVAULT="${CATALYST_KEYVAULT:-}"
CATALYST_STORAGE_ACCOUNT="${CATALYST_STORAGE_ACCOUNT:-}"
CATALYST_COSMOSDB="${CATALYST_COSMOSDB:-}"
CATALYST_SERVICEBUS="${CATALYST_SERVICEBUS:-}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Sets up an Azure user-assigned managed identity federated to a Catalyst
AppID service account via AKS workload-identity (service-account OIDC).

Options:
  --resource-group NAME    Azure resource group        (default: ${RESOURCE_GROUP})
  --location NAME          Azure location               (default: ${LOCATION})
  --cluster-name NAME      AKS cluster name             (default: ${CLUSTER_NAME})
  --project NAME           Catalyst project name        (default: ${CATALYST_PROJECT})
  --app NAME               AppID name                   (default: ${CATALYST_APP})
  --keyvault NAME          Grant 'Key Vault Secrets User' on this Key Vault              (optional)
  --storage-account NAME   Grant 'Storage Blob Data Contributor' on this account         (optional)
  --cosmosdb NAME          Grant 'Cosmos DB Built-in Data Contributor' on this account   (optional)
  --servicebus NAME        Grant 'Azure Service Bus Data Owner' on this namespace        (optional)
  -h, --help               Show this help and exit

Each option may also be supplied via an env var of the same name, e.g.:
  RESOURCE_GROUP=foo ./$(basename "$0")
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
        --location) LOCATION="$2"; shift 2 ;;
        --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
        --project) CATALYST_PROJECT="$2"; shift 2 ;;
        --app) CATALYST_APP="$2"; shift 2 ;;
        --keyvault) CATALYST_KEYVAULT="$2"; shift 2 ;;
        --storage-account) CATALYST_STORAGE_ACCOUNT="$2"; shift 2 ;;
        --cosmosdb) CATALYST_COSMOSDB="$2"; shift 2 ;;
        --servicebus) CATALYST_SERVICEBUS="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# Resolve the project/appid UIDs from the Diagrid control plane and derive the
# sidecar service account namespace/name from them.
log "Resolving UID for Catalyst project '${CATALYST_PROJECT}'..."
PROJECT_UID="$(diagrid project get "${CATALYST_PROJECT}" --output yaml | yq '.metadata.uid')"
if [[ -z "${PROJECT_UID}" || "${PROJECT_UID}" == "null" ]]; then
    echo "ERROR: could not resolve metadata.uid for project '${CATALYST_PROJECT}'." >&2
    exit 1
fi
log "Project UID: ${PROJECT_UID}"

log "Resolving UID for Catalyst appid '${CATALYST_APP}' in project '${CATALYST_PROJECT}'..."
APPID_UID="$(diagrid appid get "${CATALYST_APP}" --project "${CATALYST_PROJECT}" --output yaml | yq '.metadata.uid')"
if [[ -z "${APPID_UID}" || "${APPID_UID}" == "null" ]]; then
    echo "ERROR: could not resolve metadata.uid for appid '${CATALYST_APP}' in project '${CATALYST_PROJECT}'." >&2
    exit 1
fi
log "AppID UID: ${APPID_UID}"

# Build the sidecar service account identity from the UIDs
CATALYST_SERVICE_ACCOUNT_NAMESPACE="prj-${PROJECT_UID}"
CATALYST_SERVICE_ACCOUNT_NAME="sidecar-${PROJECT_UID}-${APPID_UID}"
log "Service account: ${CATALYST_SERVICE_ACCOUNT_NAMESPACE}/${CATALYST_SERVICE_ACCOUNT_NAME}"

# Retrieve the OIDC issuer URL for the AKS cluster (you'll need this for the federated credential setup)
log "Looking up OIDC issuer for AKS cluster '${CLUSTER_NAME}' in resource group '${RESOURCE_GROUP}'..."
AKS_OIDC_ISSUER="$(az aks show --name "${CLUSTER_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query "oidcIssuerProfile.issuerUrl" \
    --output tsv)"
log "OIDC issuer: ${AKS_OIDC_ISSUER}"

SUBSCRIPTION="$(az account show --query id --output tsv)"
log "Using subscription: ${SUBSCRIPTION}"

# A single Catalyst-wide managed identity, shared across all appids and federated
# to each appid's service account via its own federated credential (below).
USER_ASSIGNED_IDENTITY_NAME="catalyst"
if az identity show \
    --name "${USER_ASSIGNED_IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" &>/dev/null; then
    log "Managed identity '${USER_ASSIGNED_IDENTITY_NAME}' already exists; reusing it."
else
    log "Creating user-assigned managed identity '${USER_ASSIGNED_IDENTITY_NAME}'..."
    az identity create \
        --name "${USER_ASSIGNED_IDENTITY_NAME}" \
        --resource-group "${RESOURCE_GROUP}" \
        --location "${LOCATION}" \
        --subscription "${SUBSCRIPTION}" \
        --output none
fi
USER_ASSIGNED_CLIENT_ID="$(az identity show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${USER_ASSIGNED_IDENTITY_NAME}" \
    --query 'clientId' \
    --output tsv)"
PRINCIPAL_ID="$(az identity show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${USER_ASSIGNED_IDENTITY_NAME}" \
    --query 'principalId' \
    --output tsv)"
log "Client ID: ${USER_ASSIGNED_CLIENT_ID}"
log "Principal ID: ${PRINCIPAL_ID}"

FEDERATED_IDENTITY_CREDENTIAL_NAME="catalyst-${PROJECT_UID}-${APPID_UID}"
if az identity federated-credential show \
    --name "${FEDERATED_IDENTITY_CREDENTIAL_NAME}" \
    --identity-name "${USER_ASSIGNED_IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" &>/dev/null; then
    log "Federated credential '${FEDERATED_IDENTITY_CREDENTIAL_NAME}' already exists; reusing it."
else
    log "Creating federated credential '${FEDERATED_IDENTITY_CREDENTIAL_NAME}' for subject 'system:serviceaccount:${CATALYST_SERVICE_ACCOUNT_NAMESPACE}:${CATALYST_SERVICE_ACCOUNT_NAME}'..."
    az identity federated-credential create \
        --name "${FEDERATED_IDENTITY_CREDENTIAL_NAME}" \
        --identity-name "${USER_ASSIGNED_IDENTITY_NAME}" \
        --resource-group "${RESOURCE_GROUP}" \
        --issuer "${AKS_OIDC_ISSUER}" \
        --subject system:serviceaccount:"${CATALYST_SERVICE_ACCOUNT_NAMESPACE}":"${CATALYST_SERVICE_ACCOUNT_NAME}" \
        --audience api://AzureADTokenExchange \
        --output none
fi

# Optional role assignments — only run when the corresponding resource was supplied
if [[ -n "${CATALYST_KEYVAULT}" ]]; then
    log "Resolving Key Vault '${CATALYST_KEYVAULT}'..."
    KEYVAULT_SCOPE="$(az keyvault show --name "${CATALYST_KEYVAULT}" --query id --output tsv)"
    assign_role "${PRINCIPAL_ID}" "Key Vault Secrets User" "${KEYVAULT_SCOPE}" "Key Vault '${CATALYST_KEYVAULT}'"
fi

if [[ -n "${CATALYST_STORAGE_ACCOUNT}" ]]; then
    log "Resolving storage account '${CATALYST_STORAGE_ACCOUNT}'..."
    STORAGE_SCOPE="$(az storage account show --name "${CATALYST_STORAGE_ACCOUNT}" --query id --output tsv)"
    assign_role "${PRINCIPAL_ID}" "Storage Blob Data Contributor" "${STORAGE_SCOPE}" "storage account '${CATALYST_STORAGE_ACCOUNT}'"
fi

if [[ -n "${CATALYST_COSMOSDB}" ]]; then
    log "Resolving Cosmos DB account '${CATALYST_COSMOSDB}'..."
    assign_cosmos_data_role "${PRINCIPAL_ID}" "${CATALYST_COSMOSDB}" "${RESOURCE_GROUP}"
fi

if [[ -n "${CATALYST_SERVICEBUS}" ]]; then
    log "Resolving Service Bus namespace '${CATALYST_SERVICEBUS}'..."
    SERVICEBUS_SCOPE="$(az servicebus namespace show --name "${CATALYST_SERVICEBUS}" --resource-group "${RESOURCE_GROUP}" --query id --output tsv)"
    assign_role "${PRINCIPAL_ID}" "Azure Service Bus Data Owner" "${SERVICEBUS_SCOPE}" "Service Bus namespace '${CATALYST_SERVICEBUS}'"
fi

echo '--- User-Assigned Managed Identity ready ---'
echo 'Merge the following to your Catalyst chart values under agent.config:'
echo ''
echo ' agent:'
echo '   config:'
echo '     sidecar:'
echo '       service_account_annotations:'
echo '         - key: "azure.workload.identity/client-id"'
echo "           value: \"$USER_ASSIGNED_CLIENT_ID\""
echo '       pod_labels:'
echo '         - key: "azure.workload.identity/use"'
echo '           value: "true"'

