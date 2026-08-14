#!/usr/bin/env bash
# One-time bootstrap for GitHub Actions OIDC and encrypted Terraform state caching.
set -euo pipefail

GH_REPO="${GH_REPO:-Sleepyreaper/AzureSREStarterKit}"
GH_ENVIRONMENT="${GH_ENVIRONMENT:-production}"
LOCATION="${LOCATION:-swedencentral}"
WORKLOAD_RG="${WORKLOAD_RG:-rg-sre-agent-demo}"
AUTOMATION_RG="${AUTOMATION_RG:-rg-sre-agent-automation}"
IDENTITY_NAME="${IDENTITY_NAME:-id-azure-sre-starterkit-gh}"
AGENT_NAME="${AGENT_NAME:-subscription-sre-agent}"
MONTHLY_AGENT_UNIT_LIMIT="${MONTHLY_AGENT_UNIT_LIMIT:-10000}"

for command in az gh; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required." >&2
    exit 127
  fi
done

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
CURRENT_PRINCIPAL_ID="$(az ad signed-in-user show --query id -o tsv)"

echo "Bootstrapping Azure resources for ${GH_REPO} in subscription ${SUBSCRIPTION_ID}."

az group create --name "$AUTOMATION_RG" --location "$LOCATION" --only-show-errors --output none
az group create --name "$WORKLOAD_RG" --location "$LOCATION" --only-show-errors --output none

if ! az identity show --resource-group "$AUTOMATION_RG" --name "$IDENTITY_NAME" >/dev/null 2>&1; then
  az identity create \
    --resource-group "$AUTOMATION_RG" \
    --name "$IDENTITY_NAME" \
    --location "$LOCATION" \
    --only-show-errors \
    --output none
fi

CLIENT_ID="$(az identity show --resource-group "$AUTOMATION_RG" --name "$IDENTITY_NAME" --query clientId -o tsv)"
PRINCIPAL_ID="$(az identity show --resource-group "$AUTOMATION_RG" --name "$IDENTITY_NAME" --query principalId -o tsv)"
WORKLOAD_SCOPE="$(az group show --name "$WORKLOAD_RG" --query id -o tsv)"

assign_role() {
  local principal_id="$1"
  local role="$2"
  local scope="$3"

  if [[ "$(az role assignment list --scope "$scope" --query "[?principalId=='${principal_id}' && roleDefinitionName=='${role}'] | length(@)" -o tsv)" == "0" ]]; then
    az role assignment create \
      --assignee-object-id "$principal_id" \
      --assignee-principal-type ServicePrincipal \
      --role "$role" \
      --scope "$scope" \
      --only-show-errors \
      --output none
  fi
}

assign_role "$PRINCIPAL_ID" "Contributor" "$WORKLOAD_SCOPE"
assign_role "$PRINCIPAL_ID" "Role Based Access Control Administrator" "$WORKLOAD_SCOPE"

FEDERATED_SUBJECT="repo:${GH_REPO}:environment:${GH_ENVIRONMENT}"
if az identity federated-credential show \
  --resource-group "$AUTOMATION_RG" \
  --identity-name "$IDENTITY_NAME" \
  --name github-environment >/dev/null 2>&1; then
  az identity federated-credential update \
    --resource-group "$AUTOMATION_RG" \
    --identity-name "$IDENTITY_NAME" \
    --name github-environment \
    --issuer "https://token.actions.githubusercontent.com" \
    --audiences "api://AzureADTokenExchange" \
    --subject "$FEDERATED_SUBJECT" \
    --only-show-errors \
    --output none
else
  az identity federated-credential create \
    --resource-group "$AUTOMATION_RG" \
    --identity-name "$IDENTITY_NAME" \
    --name github-environment \
    --issuer "https://token.actions.githubusercontent.com" \
    --audiences "api://AzureADTokenExchange" \
    --subject "$FEDERATED_SUBJECT" \
    --only-show-errors \
    --output none
fi

gh api --method PUT "repos/${GH_REPO}/environments/${GH_ENVIRONMENT}" >/dev/null

set_environment_variable() {
  gh variable set "$1" --env "$GH_ENVIRONMENT" --repo "$GH_REPO" --body "$2"
}

set_environment_variable AZURE_CLIENT_ID "$CLIENT_ID"
set_environment_variable AZURE_DEPLOYMENT_PRINCIPAL_OBJECT_ID "$PRINCIPAL_ID"
set_environment_variable AZURE_SUBSCRIPTION_ID "$SUBSCRIPTION_ID"
set_environment_variable AZURE_TENANT_ID "$TENANT_ID"
set_environment_variable SRE_AGENT_ADMINISTRATOR_PRINCIPAL_IDS "[\"${CURRENT_PRINCIPAL_ID}\"]"
set_environment_variable SRE_AGENT_LOCATION "$LOCATION"
set_environment_variable SRE_AGENT_MONTHLY_UNIT_LIMIT "$MONTHLY_AGENT_UNIT_LIMIT"
set_environment_variable SRE_AGENT_NAME "$AGENT_NAME"
set_environment_variable SRE_AGENT_REGISTER_GITHUB_REPO "false"
set_environment_variable SRE_AGENT_RESOURCE_GROUP "$WORKLOAD_RG"

if ! gh secret list --env "$GH_ENVIRONMENT" --repo "$GH_REPO" --json name --jq '.[].name' | grep -qx TF_STATE_ENCRYPTION_KEY; then
  if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl is required to create the Terraform state encryption key." >&2
    exit 127
  fi
  openssl rand -hex 32 | gh secret set TF_STATE_ENCRYPTION_KEY --env "$GH_ENVIRONMENT" --repo "$GH_REPO"
fi

cat <<EOF
Bootstrap complete.

GitHub environment: ${GH_ENVIRONMENT}
Deployment identity: ${IDENTITY_NAME}
Terraform state: encrypted GitHub Actions cache
Workload resource group: ${WORKLOAD_RG}
EOF
