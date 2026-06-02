#!/usr/bin/env bash
# =============================================================================
# check-sre-agent.sh — verify an SRE Agent is configured for the starter kit.
#
# Prints:
#   * whether the agent exists and what state it's in
#   * its endpoint, model, scope, action mode, GitHub linkage
#   * the UAMI's role assignments on the RG it monitors
#   * which subagents are installed
#
# Usage:
#   RG=rg-sre AGENT_NAME=mysre bash scripts/check-sre-agent.sh
#   RG=rg-sre AGENT_NAME=mysre GITHUB_REPO=owner/repo bash scripts/check-sre-agent.sh
# =============================================================================
set -uo pipefail

RG="${RG:-${1:-}}"
AGENT_NAME="${AGENT_NAME:-${2:-}}"
GITHUB_REPO="${GITHUB_REPO:-${3:-}}"
API_VERSION="2025-05-01-preview"

if [[ -z "$RG" || -z "$AGENT_NAME" ]]; then
  echo "Usage: RG=rg AGENT_NAME=agent bash scripts/check-sre-agent.sh" >&2
  exit 2
fi

if ! az resource show --resource-type "Microsoft.App/agents" --name "$AGENT_NAME" -g "$RG" --api-version "$API_VERSION" >/dev/null 2>&1; then
  echo "✗ SRE Agent '$AGENT_NAME' not found in resource group '$RG'." >&2
  echo "  Create it via the portal:  https://sre.azure.com" >&2
  exit 1
fi

echo "✓ SRE Agent '$AGENT_NAME' found."
echo

az resource show --resource-type "Microsoft.App/agents" --name "$AGENT_NAME" -g "$RG" --api-version "$API_VERSION" --query "{
  endpoint: properties.agentEndpoint,
  scope: properties.knowledgeGraphConfiguration.managedResources,
  model: properties.defaultModel,
  actionMode: properties.actionConfiguration.mode,
  accessLevel: properties.actionConfiguration.accessLevel,
  state: properties.runningState,
  monthlyLimit: properties.monthlyAgentUnitLimit,
  github: properties.gitHubConfiguration,
  incidents: properties.incidentManagementConfiguration.type
}" -o yaml

echo
echo "→ UAMI permissions on $RG:"
UAMI_ID=$(az resource show --resource-type "Microsoft.App/agents" --name "$AGENT_NAME" -g "$RG" --api-version "$API_VERSION" --query "properties.knowledgeGraphConfiguration.identity" -o tsv) || true
if [[ -n "$UAMI_ID" ]]; then
  UAMI_PRINCIPAL=$(az resource show --ids "$UAMI_ID" --query "properties.principalId" -o tsv)
  az role assignment list --assignee "$UAMI_PRINCIPAL" --all -o tsv \
    --query "[?contains(scope, '/resourceGroups/${RG}') || contains(scope, '/resourceGroups/${RG,,}') || contains(scope, '/resourceGroups/${RG^^}')].roleDefinitionName" 2>/dev/null \
    | sort -u | sed 's/^/   - /'
fi

echo
echo "→ Subagents on $AGENT_NAME:"
az rest --method GET \
  --url "https://management.azure.com$(az resource show --resource-type Microsoft.App/agents --name "$AGENT_NAME" -g "$RG" --api-version "$API_VERSION" --query id -o tsv)/subagents?api-version=${API_VERSION}" \
  --query "value[].name" -o tsv 2>/dev/null | sed 's/^/   - /' || echo "   (none — or tenant doesn't support Agent Extensions; paste via portal instead)"

echo
echo "─── Required GitHub secrets (for the triage skill) ────────────"
if [[ -n "$GITHUB_REPO" ]]; then
  for s in AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_OPENAI_ENDPOINT; do
    if gh secret list --repo "$GITHUB_REPO" --json name --jq '.[].name' 2>/dev/null | grep -qx "$s"; then
      echo "  ✓ $s set on $GITHUB_REPO"
    else
      echo "  ✗ $s missing on $GITHUB_REPO  — see docs/wif-setup.md"
    fi
  done
else
  echo "  (skipped — set GITHUB_REPO=owner/repo to verify)"
fi
