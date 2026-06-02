#!/usr/bin/env bash
# Files a synthetic incident issue to exercise the triage loop without
# waiting for the real Azure SRE Agent to detect something.
#
# Usage:
#   bash scripts/simulate-sre-issue.sh "Orphaned disk drift detected"
#   bash scripts/simulate-sre-issue.sh "Open NSG rule on ogedemo-security-nsg"
set -euo pipefail

TITLE="${1:-Test SRE finding: orphaned disk}"
SCENARIO="${2:-cost}"

case "$SCENARIO" in
  storm|cost|security|reliability) ;;
  *)
    echo "Usage: $0 <title> <storm|cost|security|reliability>"
    exit 1
    ;;
esac

case "$SCENARIO" in
  storm)
    BODY="Azure SRE Agent simulated finding.

**Severity:** Medium
**Affected resource:** \`ogedemo-storm-vmss\` (Microsoft.Compute/virtualMachineScaleSets)
**Resource group:** {YOUR_RG}
**Finding:** VMSS has no autoscale settings configured. Tagged \`simulates=customer-portal-tier\`, meaning under a storm event the customer portal cannot grow with load.

ARG-QUERY: Resources | where type =~ 'Microsoft.Compute/virtualMachineScaleSets' and name == 'ogedemo-storm-vmss' | project name, sku, capacity=sku.capacity, location, tags
"
    ;;
  cost)
    BODY="Azure SRE Agent simulated finding.

**Severity:** Low
**Affected resource:** \`ogedemo-cost-orphan-disk\` (Microsoft.Compute/disks)
**Resource group:** {YOUR_RG}
**Finding:** Premium SSD 1024 GB managed disk has no managedBy reference for >30 days. Estimated waste: ~\$135/month.

ARG-QUERY: Resources | where type =~ 'Microsoft.Compute/disks' and isempty(managedBy) | project name, resourceGroup, sku=sku.name, diskSizeGB=properties.diskSizeGB
"
    ;;
  security)
    BODY="Azure SRE Agent simulated finding.

**Severity:** High
**Affected resource:** \`ogedemo-security-nsg\` (Microsoft.Network/networkSecurityGroups)
**Resource group:** {YOUR_RG}
**Finding:** NSG has inbound rules allowing SSH (port 22) and RDP (port 3389) from source 0.0.0.0/0. Anyone on the internet can attempt to reach management ports of attached subnets/NICs.

ARG-QUERY: Resources | where type =~ 'Microsoft.Network/networkSecurityGroups' and name == 'ogedemo-security-nsg' | mvexpand rule = properties.securityRules | where rule.properties.sourceAddressPrefix == '*' and rule.properties.access == 'Allow' and rule.properties.direction == 'Inbound' | project name, ruleName=rule.name, port=rule.properties.destinationPortRange, source=rule.properties.sourceAddressPrefix
"
    ;;
  reliability)
    BODY="Azure SRE Agent simulated finding.

**Severity:** Medium
**Affected resource:** \`near-expiry-cert\` in Key Vault under {YOUR_RG}
**Resource group:** {YOUR_RG}
**Finding:** TLS certificate \`near-expiry-cert\` expires in <30 days. No rotation policy attached.

ARG-QUERY: Resources | where type =~ 'Microsoft.KeyVault/vaults' and resourceGroup =~ '{YOUR_RG}' | project name, resourceGroup
"
    ;;
esac

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
echo "→ Filing simulated issue on $REPO..."
gh issue create \
  --title "$TITLE" \
  --body "$BODY" \
  --label "sre-finding,needs-triage,simulated"
