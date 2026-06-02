#!/usr/bin/env bash
# =============================================================================
# apply-sre-config.sh — Apply {YOUR_ORG} SRE Agent config to {YOUR_SRE_AGENT_NAME}
#
# Configures the existing {YOUR_SRE_AGENT_NAME} SRE Agent with:
#   1. Knowledge base files (markdown runbooks)  → data plane: AgentMemory/upload
#   2. Custom subagents (azuresre.ai/v1 YAML)    → mgmt plane: PUT /subagents/{name}
#
# Auth model:
#   - Management plane (subagents):  az account get-access-token (default audience)
#   - Data plane (memory upload):    az account get-access-token --resource https://azuresre.dev
#
# Re-run safe. Subagent PUTs are upserts.
#
# Usage:
#   bash scripts/apply-sre-config.sh
#   bash scripts/apply-sre-config.sh --kb-only         # only upload knowledge base
#   bash scripts/apply-sre-config.sh --agents-only     # only create subagents
#   bash scripts/apply-sre-config.sh --connector-only  # only set up GitHub connector
#   bash scripts/apply-sre-config.sh --with-app-telemetry        # also wire LAW + AppInsights connectors for a sister application
# =============================================================================
set -uo pipefail

RG="${RG:-{YOUR_RG}}"
AGENT_NAME="${AGENT_NAME:-{YOUR_SRE_AGENT_NAME}}"
API_VERSION="2025-05-01-preview"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

KB_ONLY=""
AGENTS_ONLY=""
CONNECTOR_ONLY=""
for arg in "$@"; do
  case "$arg" in
    --kb-only) KB_ONLY="true" ;;
    --agents-only) AGENTS_ONLY="true" ;;
    --connector-only) CONNECTOR_ONLY="true" ;;
  esac
done

if ! command -v python3 &>/dev/null; then
  echo "✗ python3 not found. Install Python 3.10+."
  exit 1
fi

echo "═══════════════════════════════════════════════════════════"
echo "  Applying {YOUR_ORG} SRE Agent config to ${AGENT_NAME}"
echo "═══════════════════════════════════════════════════════════"

# Pull the agent endpoint from ARM (data plane base URL)
AGENT_RESOURCE_ID=$(az resource show \
  --resource-type "Microsoft.App/agents" \
  --name "$AGENT_NAME" -g "$RG" \
  --api-version "$API_VERSION" \
  --query id -o tsv 2>&1)
if [[ "$AGENT_RESOURCE_ID" == *"ERROR"* ]] || [ -z "$AGENT_RESOURCE_ID" ]; then
  echo "✗ Could not find $AGENT_NAME in $RG. Verify it's deployed:"
  echo "  az resource list -g $RG --resource-type Microsoft.App/agents -o table"
  exit 1
fi
AGENT_ENDPOINT=$(az resource show \
  --resource-type "Microsoft.App/agents" \
  --name "$AGENT_NAME" -g "$RG" \
  --api-version "$API_VERSION" \
  --query "properties.agentEndpoint" -o tsv)

echo "→ Agent: $AGENT_RESOURCE_ID"
echo "→ Endpoint: $AGENT_ENDPOINT"

# ── Step 1: Upload knowledge base ────────────────────────────────────────────
if [ -z "$AGENTS_ONLY" ]; then
  echo
  echo "─── Step 1: Uploading knowledge base ──────────────────────"
  DATA_TOKEN=$(az account get-access-token --resource https://azuresre.dev --query accessToken -o tsv)
  if [ -z "$DATA_TOKEN" ]; then
    echo "✗ Could not get data-plane access token for azuresre.dev."
    echo "  Run: az login"
    exit 1
  fi

  for md in knowledge-base/*.md; do
    name=$(basename "$md")
    echo -n "  ↳ $name ... "
    RESP=$(curl -sS -X POST "${AGENT_ENDPOINT}/api/v1/AgentMemory/upload" \
      -H "Authorization: Bearer ${DATA_TOKEN}" \
      -F "triggerIndexing=true" \
      -F "files=@${md};type=text/markdown" 2>&1)
    if echo "$RESP" | grep -q "uploaded successfully"; then
      echo "uploaded"
    elif echo "$RESP" | grep -qi "error\|fail"; then
      echo "FAILED"
      echo "    $RESP" | head -3
    else
      echo "ok"
    fi
    # Indexing can race when many files upload in quick succession;
    # sleep between uploads to give the indexer headroom.
    sleep 3
  done

  echo
  echo "  Waiting 30s for indexing to complete..."
  sleep 30
  echo "  Index status:"
  curl -sS "${AGENT_ENDPOINT}/api/v1/AgentMemory/files" \
    -H "Authorization: Bearer ${DATA_TOKEN}" | python3 -c "
import json, sys
try:
  d = json.load(sys.stdin)
  for f in d.get('files', []):
    if 'knowledge_' in f.get('name', ''): continue  # skip pre-existing
    ok = '✓' if f.get('isIndexed') else '✗'
    err = f.get('errorReason') or ''
    print(f'    {ok} {f[\"name\"]:45s} {err[:60]}')
except Exception as e:
  print(f'    (could not parse: {e})')"
fi

# ── Step 2: Create subagents ────────────────────────────────────────────────
if [ -z "$KB_ONLY" ]; then
  echo
  echo "─── Step 2: Creating subagents ────────────────────────────"
  echo "  Note: subagent creation requires the 'Agent Extensions' tenant feature."
  echo "  If your tenant doesn't have it enabled, this step fails with"
  echo "  InvalidRequestParameterWithDetails — that's expected; configure"
  echo "  the same subagents via the SRE Agent portal (Builder → Agent Canvas)."
  echo
  AGENT_EXT_SUPPORTED=""
  for yaml in sre-config/agents/*.yaml; do
    NAME=$(python3 -c "import yaml,sys; print(yaml.safe_load(open('$yaml'))['spec']['name'])")
    SPEC_JSON=$(python3 -c "
import yaml, json
data = yaml.safe_load(open('$yaml'))
print(json.dumps(data['spec']))
")
    SPEC_B64=$(echo -n "$SPEC_JSON" | base64 | tr -d '\n')

    echo -n "  ↳ $NAME ... "
    RESP=$(az rest --method PUT \
      --url "https://management.azure.com${AGENT_RESOURCE_ID}/subagents/${NAME}?api-version=${API_VERSION}" \
      --body "{\"properties\":{\"value\":\"${SPEC_B64}\"}}" 2>&1)
    if echo "$RESP" | grep -q "\"name\": \"${NAME}\""; then
      echo "applied"
      AGENT_EXT_SUPPORTED="yes"
    elif echo "$RESP" | grep -qi "Agent Extensions are not available"; then
      echo "skipped (tenant gate)"
    elif echo "$RESP" | grep -qi "error\|fail"; then
      echo "FAILED"
      echo "    $(echo "$RESP" | head -3)"
    else
      echo "ok"
    fi
  done

  if [ -z "$AGENT_EXT_SUPPORTED" ]; then
    echo
    echo "  → Subagent API is gated for this tenant ('Agent Extensions' feature)."
    echo "    The YAML specs in sre-config/agents/ are still authoritative —"
    echo "    paste them into the SRE Agent portal's Agent Canvas to apply manually,"
    echo "    or wait for the feature to GA to your tenant and re-run this script."
  fi
fi

# ── Step 3: GitHub CodeRepo Registration (modern pattern) ───────────────────
# The legacy 'GitHubOAuth' connector type was deprecated. The modern pattern
# is to register a CodeRepo directly via PUT /api/v2/repos/{name} — the user's
# portal-level GitHub OAuth covers it without a per-connector auth.
if [ -z "$KB_ONLY" ] && [ -z "$AGENTS_ONLY" ]; then
  echo
  echo "─── Step 3: Register repo as a CodeRepo ────────────────────"
  DATA_TOKEN="${DATA_TOKEN:-$(az account get-access-token --resource https://azuresre.dev --query accessToken -o tsv)}"

  # Clean up any deprecated GitHubOAuth connector left over from previous runs
  if az rest --method GET \
       --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors/github?api-version=${API_VERSION}" \
       --query "properties.dataConnectorType" -o tsv 2>/dev/null | grep -q "GitHubOAuth"; then
    echo "  ↳ Removing deprecated GitHubOAuth connector ..."
    az rest --method DELETE \
      --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors/github?api-version=${API_VERSION}" \
      --output none 2>/dev/null || true
  fi

  # Register the repo as a CodeRepo
  GITHUB_REPO="${GITHUB_REPO:-{GITHUB_OWNER}/{GITHUB_REPO}}"
  REPO_NAME=$(echo "$GITHUB_REPO" | cut -d'/' -f2)
  echo -n "  ↳ Registering $GITHUB_REPO as CodeRepo ... "
  RESP=$(curl -sS -X PUT "${AGENT_ENDPOINT}/api/v2/repos/${REPO_NAME}" \
    -H "Authorization: Bearer ${DATA_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${REPO_NAME}\",\"type\":\"CodeRepo\",\"properties\":{\"url\":\"https://github.com/${GITHUB_REPO}\",\"type\":\"GitHub\"}}" \
    -w "\nHTTP_CODE=%{http_code}")
  if echo "$RESP" | grep -q "HTTP_CODE=200"; then
    echo "ok"
  else
    echo "FAILED"
    echo "$RESP" | head -3
    echo
    echo "  If you get a 401/403, finish the user-level GitHub OAuth in the portal first:"
    echo "    https://sre.azure.com  →  {YOUR_SRE_AGENT_NAME}  →  Connectors  →  GitHub"
  fi

  echo
  echo "  Waiting 15s for clone to complete..."
  sleep 15
  echo "  Repos on agent:"
  curl -sS "${AGENT_ENDPOINT}/api/v2/repos" -H "Authorization: Bearer ${DATA_TOKEN}" | python3 -c "
import json, sys
try:
  d = json.load(sys.stdin)
  for r in d.get('value', []):
    p = r['properties']
    print(f\"    • {r['name']:35s} {p.get('cloneStatus','?')}\")
except: pass"
fi

# ── Step 4: sister Cloud Weather Operations platform connectors (optional) ────────────────────
# Wires YOUR_LOG_ANALYTICS_WS (Log Analytics) + YOUR_APP_INSIGHTS (App Insights) so subagents
# can correlate app failures with infrastructure events. Skipped unless
# explicitly enabled via --with-app-telemetry.
if echo "$@" | grep -q -- --with-app-telemetry; then
  echo
  echo "─── Step 4: App telemetry connectors ──────────────────────"
  SUB=$(az account show --query id -o tsv)
  APP_INSIGHTS_ID="/subscriptions/${SUB}/resourceGroups/{CUSTOMER_RG}/providers/microsoft.insights/components/YOUR_APP_INSIGHTS"
  LOG_ANALYTICS_ID="/subscriptions/${SUB}/resourceGroups/{CUSTOMER_RG}/providers/Microsoft.OperationalInsights/workspaces/YOUR_LOG_ANALYTICS_WS"

  # Grant UAMI roles on {CUSTOMER_RG} (idempotent — Azure returns 200 if assignment exists)
  UAMI_PRINCIPAL=$(az resource show --resource-type "Microsoft.App/agents" --name "$AGENT_NAME" -g "$RG" \
    --api-version "$API_VERSION" --query "properties.knowledgeGraphConfiguration.identity" -o tsv | \
    xargs -I {} az resource show --ids {} --query "properties.principalId" -o tsv)
  {CUSTOMER_RG}_ID="/subscriptions/${SUB}/resourceGroups/{CUSTOMER_RG}"
  for ROLE in "Reader" "Monitoring Reader" "Log Analytics Reader"; do
    echo -n "  ↳ Grant '$ROLE' on {CUSTOMER_RG} ... "
    az role assignment create --assignee-object-id "$UAMI_PRINCIPAL" \
      --assignee-principal-type ServicePrincipal \
      --role "$ROLE" --scope "${CUSTOMER_RG}_ID" --output none 2>/dev/null && echo "ok" || echo "(already exists or failed)"
  done

  echo -n "  ↳ Create YOUR_APP_INSIGHTS connector ... "
  az rest --method PUT \
    --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors/YOUR_APP_INSIGHTS?api-version=${API_VERSION}" \
    --body "{\"properties\":{\"dataConnectorType\":\"AppInsights\",\"dataSource\":\"${APP_INSIGHTS_ID}\"}}" \
    --output none 2>/dev/null && echo "ok" || echo "FAILED"

  echo -n "  ↳ Create YOUR_LOG_ANALYTICS_WS connector ... "
  az rest --method PUT \
    --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors/YOUR_LOG_ANALYTICS_WS?api-version=${API_VERSION}" \
    --body "{\"properties\":{\"dataConnectorType\":\"LogAnalytics\",\"dataSource\":\"${LOG_ANALYTICS_ID}\"}}" \
    --output none 2>/dev/null && echo "ok" || echo "FAILED"
fi

echo
echo "─── Verifying ──────────────────────────────────────────────"
echo "Subagents currently on $AGENT_NAME:"
az rest --method GET \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}/subagents?api-version=${API_VERSION}" \
  --query "value[].name" -o tsv 2>&1 | sed 's/^/  • /'

echo
echo "Data connectors currently on $AGENT_NAME:"
az rest --method GET \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors?api-version=${API_VERSION}" \
  --query "value[].{name:name, type:properties.dataConnectorType, state:properties.provisioningState}" -o table 2>&1

echo
echo "Open the agent UI to test:"
echo "  $AGENT_ENDPOINT"
echo "  https://sre.azure.com   (managed portal)"
echo
echo "Try in chat:"
echo "  /agent security-fixer   then ask:  Investigate ogedemo-security-nsg"
