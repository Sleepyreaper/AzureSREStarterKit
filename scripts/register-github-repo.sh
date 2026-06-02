#!/usr/bin/env bash
# =============================================================================
# register-github-repo.sh — Register a GitHub repo as a CodeRepo on the agent.
#
# The modern Azure SRE Agent pattern doesn't use the deprecated GitHubOAuth
# data connector. User-level GitHub OAuth (signed in at https://sre.azure.com)
# covers authorization, and individual repos are added as CodeRepo resources.
#
# Prereq: user has signed into GitHub at https://sre.azure.com at least once
# so that the agent has an OAuth token for the GitHub App installation.
#
# Usage:
#   RG=rg-sre AGENT_NAME=mysre bash scripts/register-github-repo.sh owner/repo
# =============================================================================
set -uo pipefail

RG="${RG:-}"
AGENT_NAME="${AGENT_NAME:-}"
GITHUB_REPO="${1:-}"
API_VERSION="2025-05-01-preview"

if [[ -z "$RG" || -z "$AGENT_NAME" || -z "$GITHUB_REPO" || "$RG" == *"YOUR_"* ]]; then
  cat >&2 <<EOF
✗ Required values missing.

  Usage:
    export RG=rg-myorg-sre
    export AGENT_NAME=mysre
    bash scripts/register-github-repo.sh owner/repo
EOF
  exit 2
fi
if [[ "$GITHUB_REPO" != */* ]]; then
  echo "✗ GITHUB_REPO must be in 'owner/repo' form (got: $GITHUB_REPO)" >&2
  exit 2
fi

REPO_NAME="${GITHUB_REPO#*/}"

AGENT_ENDPOINT=$(az resource show \
  --resource-type "Microsoft.App/agents" --name "$AGENT_NAME" -g "$RG" \
  --api-version "$API_VERSION" --query "properties.agentEndpoint" -o tsv) || true

if [[ -z "$AGENT_ENDPOINT" ]]; then
  echo "✗ Could not find SRE Agent '$AGENT_NAME' in '$RG'." >&2
  exit 1
fi

DATA_TOKEN=$(az account get-access-token --resource https://azuresre.dev --query accessToken -o tsv)

echo "→ Registering ${GITHUB_REPO} on ${AGENT_NAME} ..."
curl -sS -X PUT "${AGENT_ENDPOINT}/api/v2/repos/${REPO_NAME}" \
  -H "Authorization: Bearer ${DATA_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${REPO_NAME}\",\"type\":\"CodeRepo\",\"properties\":{\"url\":\"https://github.com/${GITHUB_REPO}\",\"type\":\"GitHub\"}}" \
  -w "\nHTTP %{http_code}\n" | tail -3

echo
echo "→ Waiting 15s for clone ..."
sleep 15

echo "→ Status:"
curl -sS "${AGENT_ENDPOINT}/api/v2/repos/${REPO_NAME}" -H "Authorization: Bearer ${DATA_TOKEN}" \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
p = d.get("properties", {})
print(f"  cloneStatus:        {p.get(\"cloneStatus\")}")
print(f"  lastSuccessfulSync: {p.get(\"lastSuccessfulSync\")}")
print(f"  latestCommit:       {p.get(\"latestCommit\")}")
print(f"  errorMessage:       {p.get(\"errorMessage\") or \"(none)\"}")'
