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

# Defaults (override with the flags below or matching env vars). They match
# what terraform/ builds when cluster_name and location are left at theirs.
RESOURCE_GROUP="${RESOURCE_GROUP:-catalyst-rg}"
LOCATION="${LOCATION:-westus2}"
CLUSTER_NAME="${CLUSTER_NAME:-catalyst}"

CATALYST_PROJECT="${CATALYST_PROJECT:-prj1}"
CATALYST_APP="${CATALYST_APP:-app1}"
# Note: the sidecar service account namespace/name are always derived from the
# project/appid UIDs (resolved below) — they are not configurable.

# Each appid gets its own managed identity, holding the one federated credential
# for its sidecar's service account. Azure caps an identity at 20 federated
# credentials, with no wildcards, so an identity shared by appids would run out
# at 20. Empty means catalyst-<project>-<app>, or catalyst-management with
# --management.
IDENTITY_NAME="${IDENTITY_NAME:-}"

# --management sets up the regional Catalyst management service's identity
# instead of an appid's. Management resolves bring-your-own secret stores (e.g.
# Azure Key Vault) in-process for a project's workflow / agent state stores,
# authenticating as its own service account rather than any appid's. The
# service account defaults match the catalyst chart installed as release
# "catalyst" into the cra-agent namespace; override them if your install
# differs (the generated name is <release>-management-sa).
MANAGEMENT="${MANAGEMENT:-false}"
MANAGEMENT_NAMESPACE="${MANAGEMENT_NAMESPACE:-cra-agent}"
MANAGEMENT_SERVICE_ACCOUNT="${MANAGEMENT_SERVICE_ACCOUNT:-catalyst-management-sa}"

# Every identity this script creates or reuses carries this tag, so the guide's
# teardown can find them without touching the cert-manager identity terraform/
# keeps in the same resource group.
IDENTITY_TAG="catalyst-identity"

# Optional: when set, grant the identity data-plane access to these resources
CATALYST_KEYVAULT="${CATALYST_KEYVAULT:-}"
CATALYST_STORAGE_ACCOUNT="${CATALYST_STORAGE_ACCOUNT:-}"
CATALYST_COSMOSDB="${CATALYST_COSMOSDB:-}"
CATALYST_SERVICEBUS="${CATALYST_SERVICEBUS:-}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Sets up an Azure user-assigned managed identity for one Catalyst AppID,
federated to its sidecar service account via AKS workload-identity
(service-account OIDC). Run it once per AppID: each gets its own identity,
because Azure caps an identity at 20 federated credentials.

With --management, it sets up the regional Catalyst management service's
identity instead, once per region. Management resolves bring-your-own secret
stores such as Azure Key Vault in-process for a project's workflow / agent
state stores, authenticating as its own service account. Opting the management
pod into workload identity happens through Helm values; the script prints the
values to apply when it finishes.

Options:
  --resource-group NAME    Azure resource group        (default: ${RESOURCE_GROUP})
  --location NAME          Azure location               (default: ${LOCATION})
  --cluster-name NAME      AKS cluster name             (default: ${CLUSTER_NAME})
  --project NAME           Catalyst project name        (default: ${CATALYST_PROJECT})
  --app NAME               AppID name                   (default: ${CATALYST_APP})
  --identity-name NAME     Managed identity name        (default: catalyst-<project>-<app>,
                                                         or catalyst-management with --management)
  --management             Set up the management service's identity, not an AppID's;
                           --project and --app are ignored
  --management-namespace NAME        Management service account namespace   (default: ${MANAGEMENT_NAMESPACE})
  --management-service-account NAME  Management service account name        (default: ${MANAGEMENT_SERVICE_ACCOUNT})
  --keyvault NAME          Grant 'Key Vault Secrets User' + 'Key Vault Crypto User'
                           on this Key Vault, vault-wide: every key and
                           secret in it, not only the KEK                                (optional)
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
        --identity-name) IDENTITY_NAME="$2"; shift 2 ;;
        --management) MANAGEMENT=true; shift ;;
        --management-namespace) MANAGEMENT_NAMESPACE="$2"; shift 2 ;;
        --management-service-account) MANAGEMENT_SERVICE_ACCOUNT="$2"; shift 2 ;;
        --keyvault) CATALYST_KEYVAULT="$2"; shift 2 ;;
        --storage-account) CATALYST_STORAGE_ACCOUNT="$2"; shift 2 ;;
        --cosmosdb) CATALYST_COSMOSDB="$2"; shift 2 ;;
        --servicebus) CATALYST_SERVICEBUS="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# Work out the identity, the service account it trusts, and the federated
# credential that links the two.
if [[ "${MANAGEMENT}" == "true" ]]; then
    IDENTITY_NAME="${IDENTITY_NAME:-catalyst-management}"
    IDENTITY_TAG_VALUE="management"
    SERVICE_ACCOUNT_NAMESPACE="${MANAGEMENT_NAMESPACE}"
    SERVICE_ACCOUNT_NAME="${MANAGEMENT_SERVICE_ACCOUNT}"
    FEDERATED_IDENTITY_CREDENTIAL_NAME="catalyst-management"
else
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
    APPID_YAML="$(diagrid appid get "${CATALYST_APP}" --project "${CATALYST_PROJECT}" --output yaml)"
    APPID_UID="$(yq '.metadata.uid' <<<"${APPID_YAML}")"
    if [[ -z "${APPID_UID}" || "${APPID_UID}" == "null" ]]; then
        echo "ERROR: could not resolve metadata.uid for appid '${CATALYST_APP}' in project '${CATALYST_PROJECT}'." >&2
        exit 1
    fi
    log "AppID UID: ${APPID_UID}"

    # The App ID backing an Agent or MCP server is managed: it can't be updated
    # directly, so its labels and annotations are set on the owning resource.
    # The managed_by annotation is "<group>/<version>/<Kind>/<Name>/<UID>".
    OWNER_KIND="$(yq '.metadata.annotations["cra.diagrid.io/managed_by"] // ""' <<<"${APPID_YAML}" | cut -d/ -f3)"
    case "${OWNER_KIND}" in
        "") UPDATE_COMMAND="diagrid app update" ;;
        Agent) UPDATE_COMMAND="diagrid agent update" ;;
        MCPServer) UPDATE_COMMAND="diagrid mcpserver update" ;;
        *)
            echo "ERROR: appid '${CATALYST_APP}' belongs to a ${OWNER_KIND}, which doesn't support workload labels and annotations." >&2
            exit 1
            ;;
    esac

    IDENTITY_NAME="${IDENTITY_NAME:-catalyst-${CATALYST_PROJECT}-${CATALYST_APP}}"
    IDENTITY_TAG_VALUE="${CATALYST_PROJECT}/${CATALYST_APP}"
    # Build the sidecar service account identity from the UIDs
    SERVICE_ACCOUNT_NAMESPACE="prj-${PROJECT_UID}"
    SERVICE_ACCOUNT_NAME="sidecar-${PROJECT_UID}-${APPID_UID}"
    FEDERATED_IDENTITY_CREDENTIAL_NAME="catalyst-${PROJECT_UID}-${APPID_UID}"
fi
log "Service account: ${SERVICE_ACCOUNT_NAMESPACE}/${SERVICE_ACCOUNT_NAME}"

# Retrieve the OIDC issuer URL for the AKS cluster (you'll need this for the federated credential setup)
log "Looking up OIDC issuer for AKS cluster '${CLUSTER_NAME}' in resource group '${RESOURCE_GROUP}'..."
AKS_OIDC_ISSUER="$(az aks show --name "${CLUSTER_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query "oidcIssuerProfile.issuerUrl" \
    --output tsv)"
log "OIDC issuer: ${AKS_OIDC_ISSUER}"

SUBSCRIPTION="$(az account show --query id --output tsv)"
log "Using subscription: ${SUBSCRIPTION}"

if az identity show \
    --name "${IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" &>/dev/null; then
    log "Managed identity '${IDENTITY_NAME}' already exists; reusing it."
    # Tag it too, so the guide's teardown finds an identity this script didn't
    # create. Merge keeps any tags it already has; az identity update --tags
    # would replace them.
    az tag update \
        --resource-id "$(az identity show \
            --name "${IDENTITY_NAME}" \
            --resource-group "${RESOURCE_GROUP}" \
            --query id \
            --output tsv)" \
        --operation Merge \
        --tags "${IDENTITY_TAG}=${IDENTITY_TAG_VALUE}" \
        --output none
else
    log "Creating user-assigned managed identity '${IDENTITY_NAME}'..."
    az identity create \
        --name "${IDENTITY_NAME}" \
        --resource-group "${RESOURCE_GROUP}" \
        --location "${LOCATION}" \
        --subscription "${SUBSCRIPTION}" \
        --tags "${IDENTITY_TAG}=${IDENTITY_TAG_VALUE}" \
        --output none
fi
USER_ASSIGNED_CLIENT_ID="$(az identity show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${IDENTITY_NAME}" \
    --query 'clientId' \
    --output tsv)"
PRINCIPAL_ID="$(az identity show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${IDENTITY_NAME}" \
    --query 'principalId' \
    --output tsv)"
log "Client ID: ${USER_ASSIGNED_CLIENT_ID}"
log "Principal ID: ${PRINCIPAL_ID}"

if az identity federated-credential show \
    --name "${FEDERATED_IDENTITY_CREDENTIAL_NAME}" \
    --identity-name "${IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" &>/dev/null; then
    log "Federated credential '${FEDERATED_IDENTITY_CREDENTIAL_NAME}' already exists; reusing it."
else
    log "Creating federated credential '${FEDERATED_IDENTITY_CREDENTIAL_NAME}' for subject 'system:serviceaccount:${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_NAME}'..."
    az identity federated-credential create \
        --name "${FEDERATED_IDENTITY_CREDENTIAL_NAME}" \
        --identity-name "${IDENTITY_NAME}" \
        --resource-group "${RESOURCE_GROUP}" \
        --issuer "${AKS_OIDC_ISSUER}" \
        --subject system:serviceaccount:"${SERVICE_ACCOUNT_NAMESPACE}":"${SERVICE_ACCOUNT_NAME}" \
        --audience api://AzureADTokenExchange \
        --output none
fi

# Optional role assignments — only run when the corresponding resource was supplied
if [[ -n "${CATALYST_KEYVAULT}" ]]; then
    log "Resolving Key Vault '${CATALYST_KEYVAULT}'..."
    KEYVAULT_SCOPE="$(az keyvault show --name "${CATALYST_KEYVAULT}" --query id --output tsv)"
    assign_role "${PRINCIPAL_ID}" "Key Vault Secrets User" "${KEYVAULT_SCOPE}" "Key Vault '${CATALYST_KEYVAULT}'"
    # Wrap/unwrap is a separate data-plane role from reading secrets, and the
    # azurekeyvault KEK provider needs it. Granted on the whole vault, so the
    # identity can use every key in it; assign it on <vault id>/keys/<name>
    # instead to hold it to the KEK alone.
    assign_role "${PRINCIPAL_ID}" "Key Vault Crypto User" "${KEYVAULT_SCOPE}" "Key Vault '${CATALYST_KEYVAULT}'"
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
if [[ "${MANAGEMENT}" == "true" ]]; then
    echo 'Opt the management pod into workload identity by adding the following to your'
    echo 'Helm values and upgrading the catalyst release:'
    echo ''
    echo ' management:'
    echo '   podLabels:'
    echo '     azure.workload.identity/use: "true"'
    echo '   podAnnotations:'
    echo "     azure.workload.identity/client-id: \"${USER_ASSIGNED_CLIENT_ID}\""
    echo '   serviceAccount:'
    echo '     annotations:'
    echo "       azure.workload.identity/client-id: \"${USER_ASSIGNED_CLIENT_ID}\""
    echo ''
else
    echo 'Run the following Diagrid CLI command to add the workload identity label and annotation:'
    echo ''
    echo " ${UPDATE_COMMAND} ${CATALYST_APP} --project ${CATALYST_PROJECT} --label azure.workload.identity/use=true --annotation azure.workload.identity/client-id=\"$USER_ASSIGNED_CLIENT_ID\""
    echo ''
    echo 'If a workflow or agent state store references a secret via secretKeyRef, the'
    echo 'management service needs an identity of its own: run this script once per'
    echo 'region with --management.'
    echo ''
fi
