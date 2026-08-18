#!/usr/bin/env bash
#
# Wires an existing Entra ID app registration to GitHub Actions via OIDC.
# POSIX equivalent of azure-oidc-setup.ps1 - see that file for the full
# rationale behind each credential and role.
#
# Usage:
#   ./azure-oidc-setup.sh \
#       --app-client-id 00000000-0000-0000-0000-000000000000 \
#       --github-repo   owner/repo \
#       --resource-group rg-ordersapi-dev \
#       --state-storage-account stordersapitfstate001 \
#       [--state-resource-group rg-tfstate] \
#       [--state-container tfstate] \
#       [--set-github-variables]

set -euo pipefail

APP_CLIENT_ID=""
GITHUB_REPO=""
RESOURCE_GROUP=""
STATE_STORAGE_ACCOUNT=""
STATE_RESOURCE_GROUP=""
STATE_CONTAINER="tfstate"
SET_GH_VARS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-client-id)          APP_CLIENT_ID="$2"; shift 2 ;;
    --github-repo)            GITHUB_REPO="$2"; shift 2 ;;
    --resource-group)         RESOURCE_GROUP="$2"; shift 2 ;;
    --state-storage-account)  STATE_STORAGE_ACCOUNT="$2"; shift 2 ;;
    --state-resource-group)   STATE_RESOURCE_GROUP="$2"; shift 2 ;;
    --state-container)        STATE_CONTAINER="$2"; shift 2 ;;
    --set-github-variables)   SET_GH_VARS=true; shift ;;
    -h|--help)                sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

for required in APP_CLIENT_ID GITHUB_REPO RESOURCE_GROUP STATE_STORAGE_ACCOUNT; do
  if [[ -z "${!required}" ]]; then
    flag=$(echo "--${required}" | tr '[:upper:]_' '[:lower:]-')
    echo "ERROR: ${flag} is required" >&2
    exit 1
  fi
done

STATE_RESOURCE_GROUP="${STATE_RESOURCE_GROUP:-$RESOURCE_GROUP}"

if [[ ! "$GITHUB_REPO" =~ ^[^/]+/[^/]+$ ]]; then
  echo "ERROR: --github-repo must be owner/repo" >&2
  exit 1
fi

step() { printf '\n==> %s\n' "$1"; }
ok()   { printf '    [ok] %s\n' "$1"; }
skip() { printf '    [--] %s\n' "$1"; }

# ---------------------------------------------------------------------------
step "Checking prerequisites"
# ---------------------------------------------------------------------------
command -v az >/dev/null || { echo "Azure CLI not found." >&2; exit 1; }
az account show >/dev/null 2>&1 || { echo "Not logged in. Run: az login" >&2; exit 1; }

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
ok "Subscription: ${SUBSCRIPTION_ID}"
ok "Tenant:       ${TENANT_ID}"

# Role assignments target the service principal OBJECT id, not the client id.
SP_OBJECT_ID=$(az ad sp show --id "$APP_CLIENT_ID" --query id -o tsv 2>/dev/null || true)
if [[ -z "$SP_OBJECT_ID" ]]; then
  echo "    Creating service principal for app ${APP_CLIENT_ID}..."
  az ad sp create --id "$APP_CLIENT_ID" --output none
  SP_OBJECT_ID=$(az ad sp show --id "$APP_CLIENT_ID" --query id -o tsv)
fi
ok "Service principal object id: ${SP_OBJECT_ID}"

RG_ID=$(az group show --name "$RESOURCE_GROUP" --query id -o tsv)
SA_ID=$(az storage account show --name "$STATE_STORAGE_ACCOUNT" \
          --resource-group "$STATE_RESOURCE_GROUP" --query id -o tsv)
ok "Resource group:  ${RG_ID}"
ok "State account:   ${STATE_STORAGE_ACCOUNT}"

# ---------------------------------------------------------------------------
step "Creating federated credentials"
# ---------------------------------------------------------------------------
# The subject must match the OIDC token exactly. A job that declares
# `environment: dev` emits an environment subject, not a branch subject.
create_federated_credential() {
  local name="$1" subject="$2" description="$3"

  if az ad app federated-credential list --id "$APP_CLIENT_ID" \
       --query "[?subject=='${subject}'] | [0].id" -o tsv 2>/dev/null | grep -q .; then
    skip "${name} - already present"
    return
  fi

  az ad app federated-credential create --id "$APP_CLIENT_ID" --parameters "$(cat <<JSON
{
  "name": "${name}",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "${subject}",
  "description": "${description}",
  "audiences": ["api://AzureADTokenExchange"]
}
JSON
)" --output none
  ok "${name} -> ${subject}"
}

# GitHub issues OIDC subjects in one of two shapes:
#
#   classic     repo:OWNER/REPO:environment:dev
#   immutable   repo:OWNER@<ownerId>/REPO@<repoId>:environment:dev
#
# The immutable form is a hardening feature (a renamed repository cannot
# inherit the old one's trust) and is enabled per repository/organisation.
# There is no way to know in advance which you will get - you find out when a
# run fails with AADSTS700213 - so credentials are created for BOTH.
SUBJECT_PREFIXES=("repo:${GITHUB_REPO}")

if REPO_META=$(curl -fsS -H 'Accept: application/vnd.github+json' \
                 "https://api.github.com/repos/${GITHUB_REPO}" 2>/dev/null); then
  OWNER_LOGIN=$(printf '%s' "$REPO_META" | grep -o '"login"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  OWNER_ID=$(printf '%s' "$REPO_META" | grep -o '"id"[[:space:]]*:[[:space:]]*[0-9]*' | sed -n '2p' | grep -o '[0-9]*')
  REPO_ID=$(printf '%s' "$REPO_META" | grep -o '"id"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | grep -o '[0-9]*')
  REPO_NAME="${GITHUB_REPO#*/}"
  if [[ -n "$OWNER_LOGIN" && -n "$OWNER_ID" && -n "$REPO_ID" ]]; then
    SUBJECT_PREFIXES+=("repo:${OWNER_LOGIN}@${OWNER_ID}/${REPO_NAME}@${REPO_ID}")
    ok "Immutable-id subject prefix: ${SUBJECT_PREFIXES[1]}"
  fi
else
  echo "    [warn] could not read repository ids from api.github.com;" >&2
  echo "           only classic subjects will be created." >&2
fi

# slug|suffix|description
CREDENTIAL_SPECS=(
  "main-branch|ref:refs/heads/main|Pushes to main (CI build and push)"
  "pull-request|pull_request|Pull requests (terraform plan)"
  "env-dev|environment:dev|CD to dev"
  "env-prod|environment:prod|CD to prod"
  "env-infra-apply|environment:infra-apply|terraform apply"
  "env-infra-destroy|environment:infra-destroy|terraform destroy"
)

for prefix in "${SUBJECT_PREFIXES[@]}"; do
  if [[ "$prefix" == *"@"* ]]; then shape="ghid"; else shape="gh"; fi
  for spec in "${CREDENTIAL_SPECS[@]}"; do
    IFS='|' read -r slug suffix description <<< "$spec"
    create_federated_credential "${shape}-${slug}" "${prefix}:${suffix}" "$description"
  done
done

# ---------------------------------------------------------------------------
step "Assigning roles"
# ---------------------------------------------------------------------------
assign_role() {
  local role="$1" scope="$2" why="$3"

  if az role assignment list --assignee "$SP_OBJECT_ID" --scope "$scope" \
       --role "$role" --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
    skip "${role} - already assigned"
    return
  fi

  # Retry: Entra ID replication means a new SP is briefly invisible to RBAC.
  for attempt in 1 2 3 4 5; do
    if az role assignment create \
         --assignee-object-id "$SP_OBJECT_ID" \
         --assignee-principal-type ServicePrincipal \
         --role "$role" --scope "$scope" --output none 2>/dev/null; then
      ok "${role}  (${why})"
      return
    fi
    [[ $attempt -eq 5 ]] && { echo "ERROR: could not assign ${role}" >&2; exit 1; }
    echo "    retrying (${attempt}/5) - replication delay..."
    sleep 10
  done
}

assign_role "Contributor" "$RG_ID" \
  "create and manage AKS, ACR, VNet, Log Analytics"

# Contributor cannot write role assignments, and Terraform creates four.
assign_role "Role Based Access Control Administrator" "$RG_ID" \
  "Terraform creates role assignments; Contributor cannot"

# Required because the backend uses use_azuread_auth (no storage keys).
assign_role "Storage Blob Data Contributor" "$SA_ID" \
  "read/write the Terraform state blob"

assign_role "Azure Kubernetes Service Cluster User Role" "$RG_ID" \
  "fetch the cluster kubeconfig"

# ---------------------------------------------------------------------------
step "GitHub repository variables"
# ---------------------------------------------------------------------------
cat <<EOF

  Settings -> Secrets and variables -> Actions -> Variables

    AZURE_CLIENT_ID           ${APP_CLIENT_ID}
    AZURE_TENANT_ID           ${TENANT_ID}
    AZURE_SUBSCRIPTION_ID     ${SUBSCRIPTION_ID}
    AZURE_RESOURCE_GROUP      ${RESOURCE_GROUP}
    TFSTATE_RESOURCE_GROUP    ${STATE_RESOURCE_GROUP}
    TFSTATE_STORAGE_ACCOUNT   ${STATE_STORAGE_ACCOUNT}
    TFSTATE_CONTAINER         ${STATE_CONTAINER}

  Set after 'Infrastructure -> apply' (that run prints the values):
    ACR_NAME, ACR_LOGIN_SERVER, AKS_CLUSTER_NAME

  Secret: SONAR_TOKEN   (plus SONAR_ORGANIZATION / SONAR_PROJECT_KEY variables)

  Add to infra/terraform/environments/dev.tfvars:
    cicd_principal_object_id = "${SP_OBJECT_ID}"

EOF

if [[ "$SET_GH_VARS" == "true" ]]; then
  step "Setting repository variables via gh"
  if ! command -v gh >/dev/null; then
    echo "    gh CLI not found - set them manually." >&2
  else
    gh variable set AZURE_CLIENT_ID         --body "$APP_CLIENT_ID"         --repo "$GITHUB_REPO"
    gh variable set AZURE_TENANT_ID         --body "$TENANT_ID"            --repo "$GITHUB_REPO"
    gh variable set AZURE_SUBSCRIPTION_ID   --body "$SUBSCRIPTION_ID"      --repo "$GITHUB_REPO"
    gh variable set AZURE_RESOURCE_GROUP    --body "$RESOURCE_GROUP"       --repo "$GITHUB_REPO"
    gh variable set TFSTATE_RESOURCE_GROUP  --body "$STATE_RESOURCE_GROUP" --repo "$GITHUB_REPO"
    gh variable set TFSTATE_STORAGE_ACCOUNT --body "$STATE_STORAGE_ACCOUNT" --repo "$GITHUB_REPO"
    gh variable set TFSTATE_CONTAINER       --body "$STATE_CONTAINER"      --repo "$GITHUB_REPO"
    ok "variables set"
  fi
fi

printf '\nDone.\n\n'
