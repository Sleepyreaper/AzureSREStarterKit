# Runbook: Cost Waste — Orphaned & Idle Resources

> Loaded into SRE Agent memory. Use when finding unattached managed disks, unassociated public IPs, idle App Service Plans, idle VMSS, or oversized resources.

## Symptoms

| Finding | Detection signal |
|---|---|
| Orphaned managed disk | `managedBy` is empty/null, disk state = `Unattached` for >7 days |
| Unassociated public IP | `ipConfiguration` is null on `Microsoft.Network/publicIPAddresses` |
| Idle App Service Plan | `numberOfSites == 0` for >7 days |
| Oversized VM | CPU avg <10% over 30 days, memory avg <30% |
| Idle VMSS | `capacity > 0` but average CPU <5% over 14 days |

## Severity

| Monthly waste | Severity |
|---|---|
| > $500 | 🔴 **Critical** — immediate attention |
| $100 - $500 | 🟡 **Warning** — schedule cleanup |
| < $100 | 🔵 **Info** — note in next sprint cleanup |

Cost figures should always come from Azure Cost Management or pricing.azure.com — never invent them.

## Diagnostic steps

1. **Find orphaned disks** (Resource Graph):
   ```kusto
   Resources
   | where type =~ 'microsoft.compute/disks'
   | where isempty(managedBy)
   | where todatetime(properties.timeCreated) < ago(7d)
   | project name, resourceGroup, sku=sku.name, size_gb=properties.diskSizeGB, created=properties.timeCreated
   ```

2. **Find unassociated public IPs**:
   ```kusto
   Resources
   | where type =~ 'microsoft.network/publicipaddresses'
   | where isempty(properties.ipConfiguration)
   | project name, resourceGroup, sku=sku.name, allocation=properties.publicIPAllocationMethod
   ```

3. **Pull Advisor cost recommendations**:
   ```bash
   az advisor recommendation list --category Cost \
     --query "[?contains(resourceMetadata.resourceId, '{YOUR_RG}')].{resource:resourceMetadata.resourceId, savings:extendedProperties.annualSavingsAmount, recommendation:shortDescription.problem}" -o table
   ```

4. **For oversized compute, pull 30-day utilization**:
   ```bash
   az monitor metrics list --resource <resource-id> \
     --metric "Percentage CPU" \
     --interval PT1H --offset 30d \
     --aggregation Average Maximum
   ```

## Remediation patterns

### Pattern A — Delete orphaned resource (irreversible — confirm first)

For disks: **snapshot first, then delete** (defensive default). For public IPs and idle plans, direct delete is usually safe.

### Pattern B — Downgrade tier

For underutilized resources with documented future need (Premium → Standard for ~75% reduction on disks).

### Pattern C — Right-size

For oversized VMs. Verify peak utilization first — Meter Reader's rule: flag resources <30% avg as candidates, <10% as strong delete candidates.

## What to file

Use the incident-report-template. Required: Summary ("$X/month wasted on N resources"), Impact (monthly waste cite Advisor or Cost Management), Evidence (ARG query results + Advisor IDs + utilization metrics), Root Cause (forgotten cleanup / decommissioned project / IaC drift / intentional spare), Remediation (Pattern A/B/C), Risk, Verification.

## Anti-patterns

- ❌ Quoting "estimated savings" from your own reasoning — always cite Advisor or Cost Management
- ❌ Deleting disks without snapshotting first (unless empty/unattached >90 days)
- ❌ Right-sizing without 14+ days of utilization data
- ❌ Touching `{PROTECTED_RESOURCE}` or anything outside `{YOUR_RG}`
