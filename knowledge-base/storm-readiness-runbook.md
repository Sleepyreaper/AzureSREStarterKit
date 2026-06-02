# Runbook: Storm Readiness — Autoscale & Capacity

> Loaded into SRE Agent memory. Use when finding scale-out gaps (no autoscale settings, fixed-capacity compute, undersized buffers) on customer-impacting resources. Specifically relevant to seasonal-event "weather event = traffic spike" patterns.

## Symptoms

| Finding | Detection |
|---|---|
| VMSS without autoscale | No `Microsoft.Insights/autoscalesettings` references the VMSS |
| App Service Plan locked at minimum instances | `numberOfWorkers == 1` and no autoscale rule |
| AKS without cluster autoscaler | `agentPoolProfiles[0].enableAutoScaling == false` |
| HPA missing on a Deployment | `kubectl get hpa -n <ns>` empty for a customer-facing workload |
| Front Door / App Gateway capacity below 2 | Single-instance L7 = no HA |

## Severity

Multiply two factors:
- **Customer-impact** (from `simulates` tag): customer-portal-tier = high, internal-tier = medium, batch-tier = low
- **Burst factor**: how much load can spike in the worst case (storm event = 5-10x normal for portals)

| Customer impact + burst | Severity |
|---|---|
| Customer-portal + 5x+ burst | 🔴 **Critical** — fix before next forecast event |
| Customer-portal + <5x burst, OR internal + 5x+ | 🟡 **Warning** — fix this sprint |
| Internal-tier + low burst | 🔵 **Info** — add autoscale on roadmap |

## Diagnostic steps

1. **Identify customer-facing resources**:
   ```kusto
   Resources
   | where tags.simulates contains 'customer' or tags['support-owner'] != ''
   | where type in~ (
       'microsoft.compute/virtualmachinescalesets',
       'microsoft.web/serverfarms',
       'microsoft.containerservice/managedclusters',
       'microsoft.network/applicationgateways')
   | project name, type, resourceGroup, sku, capacity=properties.sku.capacity, tags
   ```

2. **Check for autoscale settings**:
   ```kusto
   Resources
   | where type =~ 'microsoft.insights/autoscalesettings'
   | project name, targetResourceUri=properties.targetResourceUri, enabled=properties.enabled
   ```

3. **Pull 14-day utilization** to size the autoscale rules correctly:
   ```bash
   az monitor metrics list --resource <vmss-id> \
     --metric "Percentage CPU" \
     --interval PT1H --offset 14d \
     --aggregation Average Maximum
   ```

4. **Check recent traffic peaks** (App Insights):
   ```kusto
   requests
   | where timestamp > ago(30d)
   | where cloud_RoleName == "<app-name>"
   | summarize rps=count() / 60 by bin(timestamp, 1m)
   | summarize p99_rps=percentile(rps, 99), max_rps=max(rps), avg_rps=avg(rps)
   ```

## Remediation patterns

### Pattern A — Add CPU-based autoscale to VMSS

Add `Microsoft.Insights/autoscalesettings` with two rules:
- Scale-out: avg CPU >70% over 5 min → +2 instances, 5 min cooldown
- Scale-in: avg CPU <30% over 10 min → -1 instance, 10 min cooldown
- Min: 2 (HA), default: 2, max: based on projected demand + 50% headroom

### Pattern B — Scheduled scale for predictable events

For storm-forecasting workloads, add a scheduled profile that pre-scales before the event (e.g., 8 instances Mon-Fri 4-9 PM ET).

### Pattern C — Switch to Container Apps / Functions for burst-bursty workloads

If the customer-facing tier is genuinely bursty (5x+ in <15 min), VMSS scaling can't keep up. Consider Azure Container Apps or Functions consumption tier where cold-start to active is <1s.

## What to file

Use the incident-report-template. Required: Summary, Impact (which scenario this maps to), Evidence (capacity + 14-day util + 30-day peak), Root Cause (`autoscale-missing` / `autoscale-disabled` / `quota-bound`), Remediation (Pattern A/B/C), Risk (cost + warm-up time + downstream saturation), Verification (synthetic load test).

## Anti-patterns

- ❌ Set max=2 — that's HA, not autoscale. Set max to actual peak + headroom.
- ❌ Average CPU with 1-min window — too jumpy. Use 5-min scale-out, 10-min scale-in.
- ❌ Forget the dependencies — autoscaling web 10x while DB stays at S1 means self-DDoS.
- ❌ Skip the load test verification — untested autoscale = no autoscale.
