#!/usr/bin/env bash
# Verifies the existing Azure SRE Agent ({YOUR_SRE_AGENT_NAME}) and prints
# what's needed to complete the GitHub integration.
#
# The agent itself was created out-of-band (Azure portal or
# az resource create). This script:
#   1. Confirms {YOUR_SRE_AGENT_NAME} exists and is running
#   2. Shows current config (model, scope, action mode, GitHub link)
#   3. Lists what still needs to be configured for the closed-loop demo
#
# Re-run safe. Read-only by default; pass --grant-rbac to add roles to its identity.
set -euo pipefail

RG="${1:-{YOUR_RG}}"
AGENT_NAME="${2:-{YOUR_SRE_AGENT_NAME}}"
REPO="${3:-{GITHUB_OWNER}/{GITHUB_REPO}}"

API_VERSION="2025-05-01-preview"

if ! az resource show --resource-type "Microsoft.App/agents" --name "$AGENT_NAME" -g "$RG" --api-version "$API_VERSION" >/dev/null 2>&1; then
  echo "✗ SRE Agent '$AGENT_NAME' not found in resource group '$RG'."
  echo "  Create it via the Azure portal (search 'SRE Agents') or:"
  echo "    https://portal.azure.com/#create/Microsoft.App%2Fagents"
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
UAMI_PRINCIPAL=$(az resource show --resource-type "Microsoft.App/agents" --name "$AGENT_NAME" -g "$RG" --api-version "$API_VERSION" --query "properties.knowledgeGraphConfiguration.identity" -o tsv | xargs -I {} az resource show --ids {} --query "properties.principalId" -o tsv)
RG_LOWER=$(echo "$RG" | tr '[:upper:]' '[:lower:]')
RG_UPPER=$(echo "$RG" | tr '[:lower:]' '[:upper:]')
# JMESPath has no case-insensitive contains; just OR both cases.
az role assignment list --assignee "$UAMI_PRINCIPAL" --all -o tsv \
  --query "[?contains(scope, '$RG') || contains(scope, '$RG_LOWER') || contains(scope, '$RG_UPPER')].roleDefinitionName" \
  | sort -u | sed 's/^/   - /'

echo
echo "─── Bridge to GitHub ─────────────────────────────────────"
GH_CONFIG=$(az resource show --resource-type "Microsoft.App/agents" --name "$AGENT_NAME" -g "$RG" --api-version "$API_VERSION" --query "properties.gitHubConfiguration" -o json)
# Treat null, {}, or {"patTokenOverride": ""} as "not configured"
GH_MEANINGFUL=$(echo "$GH_CONFIG" | jq 'if . == null then false elif (keys | length) == 0 then false elif . == {"patTokenOverride": ""} then false else true end' 2>/dev/null || echo "false")
if [ "$GH_MEANINGFUL" != "true" ]; then
  cat <<EOF
ℹ️  GitHub integration is NOT configured on the SRE Agent.

Options to bridge SRE findings → GitHub Issues on $REPO:

  A) Configure GitHub directly in the SRE Agent portal (recommended)
     1. Open the agent in Azure portal:
          https://portal.azure.com/#@/resource/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.App/agents/$AGENT_NAME
     2. In "Integrations" → "GitHub", install the GitHub App for $REPO
     3. Set the labels to apply to filed issues: sre-finding, needs-triage
     4. The agent will then file issues directly. The triage workflow
        in this repo takes over from there.

  B) Bridge via Azure Monitor Action Group + Logic App (fallback)
     Run: bash scripts/setup-azmon-github-bridge.sh
     This wires:
       SRE Agent → AzMonitor incident → Action Group (webhook)
                 → Logic App → POST /repos/$REPO/issues

  C) Manual simulation (already in place — works without any bridge)
     Run: bash scripts/simulate-sre-issue.sh "<title>" <scenario>
     Files an issue exactly like the SRE Agent would. Triage workflow
     fires the same way.
EOF
else
  echo "✓ GitHub integration is configured. Agent will file findings directly."
  echo "  Current config:"
  echo "$GH_CONFIG" | jq .
fi

echo
echo "─── Required GitHub secrets ────────────────────────────"
for s in AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_OPENAI_ENDPOINT; do
  if gh secret list --json name --jq '.[].name' 2>/dev/null | grep -qx "$s"; then
    echo "  ✓ $s set"
  else
    echo "  ✗ $s missing — see docs/runbook.md §3"
  fi
done
