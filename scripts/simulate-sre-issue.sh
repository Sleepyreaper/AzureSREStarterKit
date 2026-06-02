#!/usr/bin/env bash
# =============================================================================
# simulate-sre-issue.sh — file a synthetic SRE-style issue to exercise the
#                         triage loop without waiting for a real SRE Agent
#                         detection.
#
# The body matches the structure the triage agent expects: a one-line
# **Affected resource:** field and an `ARG-QUERY:` line so the agent can
# pre-attach Azure state when it runs.
#
# Usage:
#   bash scripts/simulate-sre-issue.sh "<title>" <scenario> [resource-name] [resource-group]
#
# Scenarios:
#   storm        — VMSS without autoscale
#   cost         — orphaned premium disk
#   security     — NSG open to the internet
#   reliability  — near-expiry Key Vault cert
#
# Examples:
#   bash scripts/simulate-sre-issue.sh "Orphaned disk drift" cost orphan-disk-01 rg-prod
#   bash scripts/simulate-sre-issue.sh "Open NSG rule" security web-nsg rg-prod
# =============================================================================
set -euo pipefail

TITLE="${1:?usage: $0 <title> <storm|cost|security|reliability> [resource] [rg]}"
SCENARIO="${2:?usage: $0 <title> <storm|cost|security|reliability> [resource] [rg]}"
RESOURCE="${3:-my-resource}"
TARGET_RG="${4:-${YOUR_RG:-${RG:-rg-demo}}}"

case "$SCENARIO" in
  storm|cost|security|reliability) ;;
  *)
    echo "✗ scenario must be one of: storm, cost, security, reliability" >&2
    exit 2
    ;;
esac

case "$SCENARIO" in
  storm)
    BODY="Azure SRE Agent simulated finding.

**Severity:** Medium
**Affected resource:** \`${RESOURCE}\` (Microsoft.Compute/virtualMachineScaleSets)
**Resource group:** \`${TARGET_RG}\`
**Finding:** VMSS has no autoscale settings configured. Tagged \`simulates=customer-portal-tier\`, meaning under a traffic spike the tier cannot grow with load.

ARG-QUERY: Resources | where type =~ 'Microsoft.Compute/virtualMachineScaleSets' and name == '${RESOURCE}' | project name, sku, capacity=sku.capacity, location, tags
"
    LABELS="sre-finding,needs-triage,scenario:storm,simulated"
    ;;
  cost)
    BODY="Azure SRE Agent simulated finding.

**Severity:** Low
**Affected resource:** \`${RESOURCE}\` (Microsoft.Compute/disks)
**Resource group:** \`${TARGET_RG}\`
**Finding:** Premium SSD managed disk has no \`managedBy\` reference for >30 days. Estimated waste per Azure Advisor.

ARG-QUERY: Resources | where type =~ 'Microsoft.Compute/disks' and name == '${RESOURCE}' and isempty(managedBy) | project name, resourceGroup, sku=sku.name, diskSizeGB=properties.diskSizeGB
"
    LABELS="sre-finding,needs-triage,scenario:cost,simulated"
    ;;
  security)
    BODY="Azure SRE Agent simulated finding.

**Severity:** High
**Affected resource:** \`${RESOURCE}\` (Microsoft.Network/networkSecurityGroups)
**Resource group:** \`${TARGET_RG}\`
**Finding:** NSG has inbound rules allowing SSH (port 22) and/or RDP (port 3389) from source 0.0.0.0/0. Anyone on the internet can attempt to reach management ports of attached subnets/NICs.

ARG-QUERY: Resources | where type =~ 'Microsoft.Network/networkSecurityGroups' and name == '${RESOURCE}' | mv-expand rule = properties.securityRules | where rule.properties.sourceAddressPrefix == '*' and rule.properties.access == 'Allow' and rule.properties.direction == 'Inbound' | project name, ruleName=rule.name, port=rule.properties.destinationPortRange, source=rule.properties.sourceAddressPrefix
"
    LABELS="sre-finding,needs-triage,scenario:security,simulated"
    ;;
  reliability)
    BODY="Azure SRE Agent simulated finding.

**Severity:** Medium
**Affected resource:** \`${RESOURCE}\` (a TLS certificate in a Key Vault under \`${TARGET_RG}\`)
**Resource group:** \`${TARGET_RG}\`
**Finding:** TLS certificate \`${RESOURCE}\` expires in <30 days. No rotation policy attached.

ARG-QUERY: Resources | where type =~ 'Microsoft.KeyVault/vaults' and resourceGroup =~ '${TARGET_RG}' | project name, resourceGroup, location, sku=properties.sku.name
"
    LABELS="sre-finding,needs-triage,scenario:reliability,simulated"
    ;;
esac

if ! command -v gh &>/dev/null; then
  echo "✗ gh CLI not found. https://cli.github.com" >&2
  exit 1
fi

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
echo "→ Filing simulated issue on $REPO ..."
gh issue create \
  --title "$TITLE" \
  --body "$BODY" \
  --label "$LABELS"
