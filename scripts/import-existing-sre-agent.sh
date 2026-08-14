#!/usr/bin/env bash
# Import an existing starter-kit deployment when no cached Terraform state exists.
set -euo pipefail

TF_DIR="${TF_DIR:-infra/terraform/sre-agent}"
RG="${TF_VAR_resource_group_name:-${RG:-}}"
AGENT_NAME="${TF_VAR_agent_name:-${AGENT_NAME:-}}"
NAME_PREFIX="${TF_VAR_name_prefix:-sre-agent-demo}"

if [[ -z "$RG" || -z "$AGENT_NAME" ]]; then
  echo "TF_VAR_resource_group_name and TF_VAR_agent_name are required." >&2
  exit 2
fi

state_has() {
  terraform -chdir="$TF_DIR" state show "$1" >/dev/null 2>&1
}

import_resource() {
  local address="$1"
  local resource_id="$2"

  if [[ -z "$resource_id" || "$resource_id" == "null" ]] || state_has "$address"; then
    return
  fi
  echo "Importing ${address}."
  terraform -chdir="$TF_DIR" import "$address" "$resource_id"
}

resource_id() {
  if az resource show \
    --resource-group "$RG" \
    --resource-type "$1" \
    --name "$2" \
    --api-version "$3" \
    >/dev/null 2>&1; then
    printf '%s/providers/%s/%s\n' "$RG_ID" "$1" "$2"
  fi
}

RG_ID="$(az group show --name "$RG" --query id -o tsv)"
LAW_ID="$(resource_id Microsoft.OperationalInsights/workspaces "law-${NAME_PREFIX}" 2025-02-01)"
APPI_ID="$(resource_id Microsoft.Insights/components "appi-${NAME_PREFIX}" 2020-02-02)"
ACTION_GROUP_ID="$(resource_id Microsoft.Insights/actionGroups "ag-${NAME_PREFIX}-sre-agent" 2023-01-01)"
IDENTITY_ID="$(resource_id Microsoft.ManagedIdentity/userAssignedIdentities "id-${AGENT_NAME}" 2023-01-31)"
AGENT_ID="$(resource_id Microsoft.App/agents "$AGENT_NAME" 2025-05-01-preview)"

import_resource azurerm_log_analytics_workspace.agent "$LAW_ID"
import_resource azurerm_application_insights.agent "$APPI_ID"
import_resource azurerm_monitor_action_group.agent "$ACTION_GROUP_ID"
import_resource azurerm_user_assigned_identity.agent "$IDENTITY_ID"

if [[ -n "$IDENTITY_ID" ]]; then
  IDENTITY_PRINCIPAL_ID="$(az identity show --ids "$IDENTITY_ID" --query principalId -o tsv)"

  import_role() {
    local address="$1"
    local role="$2"
    local scope="$3"
    local assignment_id
    assignment_id="$(az role assignment list \
      --scope "$scope" \
      --query "[?principalId=='${IDENTITY_PRINCIPAL_ID}' && roleDefinitionName=='${role}'].id | [0]" \
      -o tsv)"
    import_resource "$address" "$assignment_id"
  }

  import_role azurerm_role_assignment.managed_resource_reader "Reader" "$RG_ID"
  import_role azurerm_role_assignment.managed_resource_monitoring_reader "Monitoring Reader" "$RG_ID"
  import_role azurerm_role_assignment.monitoring_contributor "Monitoring Contributor" "$RG_ID"
  if [[ -n "$LAW_ID" ]]; then
    import_role azurerm_role_assignment.log_analytics_reader "Log Analytics Reader" "$LAW_ID"
  fi
fi

if [[ -n "$AGENT_ID" ]]; then
  import_resource azapi_resource.agent "${AGENT_ID}?api-version=2025-05-01-preview"
fi

if [[ -n "$AGENT_ID" ]]; then
  python3 - <<'PY' | while IFS= read -r principal_id; do
import json
import os

for principal_id in json.loads(os.environ.get("TF_VAR_administrator_principal_ids", "[]")):
    print(principal_id)
PY
    assignment_id="$(az role assignment list \
      --scope "$AGENT_ID" \
      --query "[?principalId=='${principal_id}' && roleDefinitionName=='SRE Agent Administrator'].id | [0]" \
      -o tsv)"
    import_resource "azurerm_role_assignment.agent_administrator[\"${principal_id}\"]" "$assignment_id"
  done

  if [[ -n "${TF_VAR_deployment_principal_object_id:-}" ]]; then
    assignment_id="$(az role assignment list \
      --scope "$AGENT_ID" \
      --query "[?principalId=='${TF_VAR_deployment_principal_object_id}' && roleDefinitionName=='SRE Agent Administrator'].id | [0]" \
      -o tsv)"
    import_resource 'azurerm_role_assignment.deployment_agent_administrator[0]' "$assignment_id"
  fi
fi
