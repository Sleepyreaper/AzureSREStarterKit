#!/usr/bin/env bash
# =============================================================================
# apply-sre-config.sh — Apply this starter kit to your Azure SRE Agent
#
# Configures an existing SRE Agent with:
#   1. Knowledge base files (markdown runbooks)  → data plane: AgentMemory/upload
#   2. Custom subagents (azuresre.ai/v1 YAML)    → mgmt plane: PUT /subagents/{name}
#   3. (Optional) GitHub CodeRepo registration
#   4. (Optional) App telemetry connectors (Log Analytics + Application Insights)
#
# Auth model:
#   - Management plane (subagents):  az account get-access-token (default audience)
#   - Data plane (memory upload):    az account get-access-token --resource https://azuresre.dev
#
# Re-run safe. Subagent PUTs are upserts.
#
# Required environment variables (export before running, or pass on the CLI):
#   RG                — resource group hosting your SRE Agent
#   AGENT_NAME        — your SRE Agent resource name
# Optional:
#   GITHUB_REPO       — "owner/repo" to register as CodeRepo (Step 3)
#   APP_INSIGHTS_ID   — full ARM ID of an Application Insights component (Step 4)
#   LOG_ANALYTICS_ID  — full ARM ID of a Log Analytics workspace (Step 4)
#
# Usage:
#   RG=rg-sre AGENT_NAME=mysre bash scripts/apply-sre-config.sh
#   bash scripts/apply-sre-config.sh --kb-only
#   bash scripts/apply-sre-config.sh --agents-only
#   bash scripts/apply-sre-config.sh --repo-only
#   bash scripts/apply-sre-config.sh --with-app-telemetry
# =============================================================================
set -uo pipefail

RG="${RG:-}"
AGENT_NAME="${AGENT_NAME:-}"
GITHUB_REPO="${GITHUB_REPO:-}"
APP_INSIGHTS_ID="${APP_INSIGHTS_ID:-}"
LOG_ANALYTICS_ID="${LOG_ANALYTICS_ID:-}"
API_VERSION="2025-05-01-preview"

# Refuse to run if required vars are missing or still placeholders.
if [[ -z "$RG" || -z "$AGENT_NAME" || "$RG" == *"YOUR_"* || "$AGENT_NAME" == *"YOUR_"* ]]; then
  cat >&2 <<EOF
✗ RG and AGENT_NAME must be set to real values (not placeholders).

  Example:
    export RG=rg-myorg-sre
    export AGENT_NAME=mysre
    bash scripts/apply-sre-config.sh

EOF
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

KB_ONLY=""
AGENTS_ONLY=""
REPO_ONLY=""
WITH_APP_TELEMETRY=""
for arg in "$@"; do
  case "$arg" in
    --kb-only) KB_ONLY="true" ;;
    --agents-only) AGENTS_ONLY="true" ;;
    --repo-only) REPO_ONLY="true" ;;
    --with-app-telemetry) WITH_APP_TELEMETRY="true" ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
  esac
done

if ! command -v python3 &>/dev/null; then
  echo "✗ python3 not found. Install Python 3.10+." >&2
  exit 1
fi
if ! command -v az &>/dev/null; then
  echo "✗ az CLI not found. https://aka.ms/azcli" >&2
  exit 1
fi
# PyYAML is only needed for the subagent step; checked just-in-time below.

echo "═══════════════════════════════════════════════════════════"
echo "  Applying starter-kit config to ${AGENT_NAME} in ${RG}"
echo "═══════════════════════════════════════════════════════════"

# Pull the agent endpoint from ARM (data plane base URL)
AGENT_RESOURCE_ID=$(az resource show \
  --resource-type "Microsoft.App/agents" \
  --name "$AGENT_NAME" -g "$RG" \
  --api-version "$API_VERSION" \
  --query id -o tsv 2>/dev/null) || true

if [ -z "$AGENT_RESOURCE_ID" ]; then
  echo "✗ Could not find SRE Agent '$AGENT_NAME' in resource group '$RG'." >&2
  echo "  Verify with:  az resource list -g $RG --resource-type Microsoft.App/agents -o table" >&2
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
if [ -z "$AGENTS_ONLY" ] && [ -z "$REPO_ONLY" ]; then
  echo
  echo "─── Step 1: Uploading knowledge base ──────────────────────"
  DATA_TOKEN=$(az account get-access-token --resource https://azuresre.dev --query accessToken -o tsv)
  if [ -z "$DATA_TOKEN" ]; then
    echo "✗ Could not get data-plane access token for azuresre.dev. Run: az login" >&2
    exit 1
  fi

  for md in knowledge-base/*.md; do
    [ -e "$md" ] || { echo "  (no knowledge-base/*.md files found)"; break; }
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
    -H "Authorization: Bearer ${DATA_TOKEN}" | python3 -c '
import json, sys
try:
  d = json.load(sys.stdin)
  for f in d.get("files", []):
    if "knowledge_" in f.get("name", ""): continue  # skip pre-existing
    ok = "✓" if f.get("isIndexed") else "✗"
    err = f.get("errorReason") or ""
    print(f"    {ok} {f[\"name\"]:45s} {err[:60]}")
except Exception as e:
  print(f"    (could not parse: {e})")'
fi

# ── Step 2: Create subagents ────────────────────────────────────────────────
if [ -z "$KB_ONLY" ] && [ -z "$REPO_ONLY" ]; then
  echo
  echo "─── Step 2: Creating subagents ────────────────────────────"
  if ! python3 -c "import yaml" 2>/dev/null; then
    echo "  ✗ PyYAML not installed.  Run:  python3 -m pip install --user PyYAML"
    echo "  Skipping subagent step."
  else
  echo "  NOTE: subagent creation requires the 'Agent Extensions' tenant feature."
  echo "        If your tenant doesn't have it enabled, this step is skipped"
  echo "        and you should paste the YAML manually via the SRE Agent portal"
  echo "        (Builder → Agent Canvas). See docs/subagent-paste-cheatsheet.md."
  echo
  AGENT_EXT_SUPPORTED=""
  for yaml in subagents/*.yaml; do
    [ -e "$yaml" ] || { echo "  (no subagents/*.yaml files found)"; break; }

    NAME=$(python3 -c "import yaml,sys; print(yaml.safe_load(open('$yaml'))['spec']['name'])")
    SPEC_JSON=$(python3 -c "
import yaml, json
print(json.dumps(yaml.safe_load(open('$yaml'))['spec']))
")
    SPEC_B64=$(printf '%s' "$SPEC_JSON" | base64 | tr -d '\n')

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
    echo "  → Subagent API is gated for this tenant. Paste the same specs"
    echo "    via the portal — see docs/subagent-paste-cheatsheet.md."
  fi
  fi  # end PyYAML availability gate
fi

# ── Step 2.5: RBAC on the monitored RG ──────────────────────────────────────
# The agent's User-Assigned Managed Identity needs read access on the RG
# whose resources it investigates. Without this, even though the KG is scoped
# to the RG, az CLI calls run by subagents will fail with 403.
if [ -z "$KB_ONLY" ] && [ -z "$REPO_ONLY" ] && [ -z "$AGENTS_ONLY" ]; then
  echo
  echo "─── Step 2.5: RBAC on monitored RG ($RG) ──────────────────"
  UAMI_ID=$(az resource show --resource-type "Microsoft.App/agents" --name "$AGENT_NAME" -g "$RG" \
    --api-version "$API_VERSION" --query "properties.knowledgeGraphConfiguration.identity" -o tsv 2>/dev/null) || true
  if [ -n "$UAMI_ID" ]; then
    UAMI_PRINCIPAL=$(az resource show --ids "$UAMI_ID" --query "properties.principalId" -o tsv 2>/dev/null) || true
    RG_SCOPE=$(az group show -n "$RG" --query id -o tsv 2>/dev/null) || true
    if [ -n "$UAMI_PRINCIPAL" ] && [ -n "$RG_SCOPE" ]; then
      for ROLE in "Reader" "Monitoring Reader" "Log Analytics Reader"; do
        echo -n "  ↳ Grant '$ROLE' on $RG ... "
        az role assignment create --assignee-object-id "$UAMI_PRINCIPAL" \
          --assignee-principal-type ServicePrincipal \
          --role "$ROLE" --scope "$RG_SCOPE" --output none 2>/dev/null \
          && echo "ok" || echo "(already exists or failed)"
      done
    else
      echo "  (skipped — could not resolve UAMI principal or RG scope)"
    fi
  else
    echo "  (skipped — agent has no knowledgeGraphConfiguration.identity yet)"
  fi
fi

# ── Step 3: GitHub CodeRepo Registration ────────────────────────────────────
# The legacy 'GitHubOAuth' connector type was deprecated. The modern pattern
# is to register each repo via PUT /api/v2/repos/{name}; the portal-level
# GitHub OAuth covers authorization.
if [ -n "$GITHUB_REPO" ] || [ -n "$REPO_ONLY" ]; then
  GITHUB_REPO="${GITHUB_REPO:-}"
  if [ -z "$GITHUB_REPO" ] || [[ "$GITHUB_REPO" == *"YOUR_"* ]] || [[ "$GITHUB_REPO" == *"GITHUB_"* ]]; then
    echo
    echo "─── Step 3: Skipped — set GITHUB_REPO=owner/repo to register ───"
  else
    echo
    echo "─── Step 3: Register repo as a CodeRepo ────────────────────"
    DATA_TOKEN="${DATA_TOKEN:-$(az account get-access-token --resource https://azuresre.dev --query accessToken -o tsv)}"

    if az rest --method GET \
         --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors/github?api-version=${API_VERSION}" \
         --query "properties.dataConnectorType" -o tsv 2>/dev/null | grep -q "GitHubOAuth"; then
      echo "  ↳ Removing deprecated GitHubOAuth connector ..."
      az rest --method DELETE \
        --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors/github?api-version=${API_VERSION}" \
        --output none 2>/dev/null || true
    fi

    REPO_NAME="${GITHUB_REPO#*/}"
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
      echo "  If 401/403, finish the user-level GitHub OAuth in the portal first:"
      echo "    https://sre.azure.com  →  ${AGENT_NAME}  →  Connectors  →  GitHub"
    fi

    echo
    echo "  Waiting 15s for clone to complete..."
    sleep 15
    echo "  Repos on agent:"
    curl -sS "${AGENT_ENDPOINT}/api/v2/repos" -H "Authorization: Bearer ${DATA_TOKEN}" | python3 -c '
import json, sys
try:
  d = json.load(sys.stdin)
  for r in d.get("value", []):
    p = r["properties"]
    print(f"    • {r[\"name\"]:35s} {p.get(\"cloneStatus\",\"?\")}")
except Exception:
  pass'
  fi
fi

# ── Step 4: Application telemetry connectors (optional) ─────────────────────
# Wires a Log Analytics workspace + Application Insights so subagents can
# correlate app failures with infrastructure events. Skipped unless
# explicitly enabled via --with-app-telemetry AND APP_INSIGHTS_ID +
# LOG_ANALYTICS_ID env vars are set.
if [ -n "$WITH_APP_TELEMETRY" ]; then
  APP_INSIGHTS_ID="${APP_INSIGHTS_ID:-}"
  LOG_ANALYTICS_ID="${LOG_ANALYTICS_ID:-}"
  if [ -z "$APP_INSIGHTS_ID" ] || [ -z "$LOG_ANALYTICS_ID" ]; then
    echo
    echo "─── Step 4: Skipped — set APP_INSIGHTS_ID and LOG_ANALYTICS_ID ───"
    echo "    Both must be full ARM resource IDs."
  else
    echo
    echo "─── Step 4: App telemetry connectors ──────────────────────"

    APPI_NAME="${APP_INSIGHTS_ID##*/}"
    LAW_NAME="${LOG_ANALYTICS_ID##*/}"

    # Grant agent's UAMI Reader + Monitoring Reader + Log Analytics Reader
    # on the RGs that own those resources, so the connectors can read data.
    UAMI_ID=$(az resource show --resource-type "Microsoft.App/agents" --name "$AGENT_NAME" -g "$RG" \
      --api-version "$API_VERSION" --query "properties.knowledgeGraphConfiguration.identity" -o tsv)
    UAMI_PRINCIPAL=$(az resource show --ids "$UAMI_ID" --query "properties.principalId" -o tsv)

    # Derive scopes from full ARM IDs of the supplied resources.
    APPI_RG_SCOPE="$(echo "$APP_INSIGHTS_ID" | sed -E 's|(/resourceGroups/[^/]+).*|\1|')"
    LAW_RG_SCOPE="$(echo "$LOG_ANALYTICS_ID" | sed -E 's|(/resourceGroups/[^/]+).*|\1|')"
    for SCOPE in "$APPI_RG_SCOPE" "$LAW_RG_SCOPE"; do
      for ROLE in "Reader" "Monitoring Reader" "Log Analytics Reader"; do
        echo -n "  ↳ Grant '$ROLE' on $(basename "$SCOPE") ... "
        az role assignment create --assignee-object-id "$UAMI_PRINCIPAL" \
          --assignee-principal-type ServicePrincipal \
          --role "$ROLE" --scope "$SCOPE" --output none 2>/dev/null \
          && echo "ok" || echo "(already exists or failed)"
      done
    done

    echo -n "  ↳ Create '$APPI_NAME' AppInsights connector ... "
    az rest --method PUT \
      --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors/${APPI_NAME}?api-version=${API_VERSION}" \
      --body "{\"properties\":{\"dataConnectorType\":\"AppInsights\",\"dataSource\":\"${APP_INSIGHTS_ID}\"}}" \
      --output none 2>/dev/null && echo "ok" || echo "FAILED"

    echo -n "  ↳ Create '$LAW_NAME' LogAnalytics connector ... "
    az rest --method PUT \
      --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors/${LAW_NAME}?api-version=${API_VERSION}" \
      --body "{\"properties\":{\"dataConnectorType\":\"LogAnalytics\",\"dataSource\":\"${LOG_ANALYTICS_ID}\"}}" \
      --output none 2>/dev/null && echo "ok" || echo "FAILED"
  fi
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
echo "  /agent security-fixer    then ask:  Investigate an NSG named <your-nsg> in $RG"
