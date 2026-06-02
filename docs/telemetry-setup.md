# Telemetry Setup — Azure Monitor, Log Analytics, Application Insights

This guide is the **prerequisite** to running the Azure SRE Agent and the triage skill from this kit. The subagents reason over **what they can see** — if your resources don't emit diagnostic logs to a Log Analytics Workspace the agent can read, the runbooks fall back to whatever Azure Resource Graph snapshots tell them, which is a much weaker signal.

This doc covers:

1. The signal flow (who emits what, who reads what)
2. The two backend resources you need: **Log Analytics Workspace (LAW)** and **Application Insights**
3. Wiring them as **Data Connectors** on your SRE Agent
4. What telemetry each subagent in this kit actually consumes
5. Operational settings (retention, sampling, cost guardrails)

For **enforcing** these settings across new resources, see [`policy-enforcement.md`](policy-enforcement.md).

---

## 1. Signal flow

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Azure resources in {YOUR_RG}                                             │
│   VMSS · NSG · Key Vault · App Service · Storage · OpenAI · AKS · ...    │
└───────────────────────────────────┬──────────────────────────────────────┘
                                    │ Diagnostic Settings
                                    │ (per-resource, set once,
                                    │  policy-enforced thereafter)
                                    ▼
                       ┌────────────────────────────┐
                       │ Log Analytics Workspace    │  ← the SRE Agent reads
                       │ {YOUR_LOG_ANALYTICS_WS}    │    this via the
                       └─────────────┬──────────────┘    LogAnalytics connector
                                     │ (workspace-based)
                                     ▼
                       ┌────────────────────────────┐
                       │ Application Insights       │  ← agent reads via
                       │ {YOUR_APP_INSIGHTS}        │    the AppInsights
                       └────────────────────────────┘    connector
                                     ▲
                                     │  OTel / appinsights SDK
                                     │  emits from your app code
                       ┌────────────────────────────┐
                       │ App workload (Flask / .NET │
                       │ / Node / Functions / ...)  │
                       └────────────────────────────┘

Azure Monitor *Metrics* and *Activity Log* are read by the SRE Agent
directly via its built-in Azure Resource Graph + Azure Monitor REST APIs
— no extra plumbing required, but the UAMI needs Monitoring Reader at
the appropriate scope (granted by scripts/apply-sre-config.sh Step 2.5).
```

The three telemetry types and where they live:

| Source | Type | Destination | How the agent reads it |
|---|---|---|---|
| Resource diagnostic logs (NSG flow, KV audit, AppService stdout, etc.) | Logs | LAW | KQL via `QueryLogAnalyticsByWorkspaceId` |
| Resource & platform metrics | Metrics | Azure Monitor metric store | `RunAzCliReadCommands` (`az monitor metrics list ...`) — no setup needed |
| Activity Log (control-plane writes) | Logs | Azure Monitor → optional LAW mirror | `RunAzCliReadCommands` (`az monitor activity-log list ...`) |
| App telemetry (requests, dependencies, exceptions, traces) | Logs (workspace-based) | App Insights → backing LAW | KQL via `QueryAppInsightsByResourceId` |
| Defender for Cloud findings | Alerts | LAW (`SecurityAlert` table) | `QueryLogAnalyticsByWorkspaceId` |

The two settings that matter most:

1. **Diagnostic settings are per-resource.** Creating a LAW does *nothing* by itself. You must either set diagnostic settings per resource (manual + error-prone) or **use policy** to make Azure auto-attach them. See [`policy-enforcement.md`](policy-enforcement.md).
2. **App Insights must be workspace-based.** Classic (instrumentation-key-only) App Insights cannot be queried by the SRE Agent's connector. If you have a classic component, migrate first: `az monitor app-insights component update --workspace ...`.

---

## 2. Create the backend resources

### Variables

```bash
SUB=$(az account show --query id -o tsv)
LOCATION=eastus2
TEL_RG=rg-shared-telemetry            # any RG; doesn't need to be the monitored RG
LAW_NAME=law-shared-${SUB:0:8}
APPI_NAME=appi-shared-${SUB:0:8}
```

### Log Analytics Workspace

```bash
az group create -n "$TEL_RG" -l "$LOCATION" --only-show-errors

az monitor log-analytics workspace create \
  -g "$TEL_RG" -n "$LAW_NAME" -l "$LOCATION" \
  --retention-time 30 \
  --sku PerGB2018 \
  --only-show-errors

LAW_ID=$(az monitor log-analytics workspace show -g "$TEL_RG" -n "$LAW_NAME" --query id -o tsv)
echo "LAW_ID=$LAW_ID"
```

Defaults to **30 days retention** and **Pay-As-You-Go (PerGB2018)** SKU — sane for getting started. For production, consider:

- **Daily cap** to prevent runaway cost: `--daily-quota-gb 5` (alerts you at 80 %, hard-stops ingestion at 100 % until midnight UTC).
- **Commitment tier** if you're ingesting >100 GB/day — significant per-GB discount.
- **Retention** by table — set hot retention to 30 days, archive cheaper tiers up to 12 years for compliance tables only.

### Application Insights (workspace-based)

```bash
az extension add -n application-insights --only-show-errors 2>/dev/null || true

az monitor app-insights component create \
  -g "$TEL_RG" -a "$APPI_NAME" -l "$LOCATION" \
  --workspace "$LAW_ID" \
  --kind web \
  --application-type web \
  --only-show-errors

APPI_ID=$(az monitor app-insights component show -g "$TEL_RG" -a "$APPI_NAME" --query id -o tsv)
APPI_CONN=$(az monitor app-insights component show -g "$TEL_RG" -a "$APPI_NAME" --query connectionString -o tsv)
echo "APPI_ID=$APPI_ID"
echo "APPI_CONN=$APPI_CONN"   # this is the secret to set in your app
```

### Wire diagnostic settings to LAW (one resource — example)

Manual one-off, useful for testing before turning on the policy:

```bash
# Example: send Key Vault audit events to LAW
KV_ID=$(az keyvault show -n {your-kv} -g {YOUR_RG} --query id -o tsv)
az monitor diagnostic-settings create \
  --name to-shared-law \
  --resource "$KV_ID" \
  --workspace "$LAW_ID" \
  --logs '[{"categoryGroup":"audit","enabled":true},{"categoryGroup":"allLogs","enabled":true}]' \
  --metrics '[{"category":"AllMetrics","enabled":true}]' \
  --only-show-errors
```

Use the **policy-driven** approach in [`policy-enforcement.md`](policy-enforcement.md) for everything else — it scales, it's idempotent, and it survives drift.

---

## 3. Register LAW + App Insights with the SRE Agent

The `apply-sre-config.sh` script wires both in one step. With `LAW_ID` and `APPI_ID` from above:

```bash
export RG=rg-your-monitored-rg
export AGENT_NAME=your-sre-agent
export LOG_ANALYTICS_ID="$LAW_ID"
export APP_INSIGHTS_ID="$APPI_ID"
bash scripts/apply-sre-config.sh --with-app-telemetry
```

What that does:

1. Grants the SRE Agent's UAMI **Reader · Monitoring Reader · Log Analytics Reader** on the LAW's and App Insights' parent resource groups.
2. Creates `Microsoft.App/agents/{name}/DataConnectors/{LAW_NAME}` with `dataConnectorType=LogAnalytics`.
3. Creates `Microsoft.App/agents/{name}/DataConnectors/{APPI_NAME}` with `dataConnectorType=AppInsights`.

After this, subagents can use the `QueryLogAnalyticsByWorkspaceId` and `QueryAppInsightsByResourceId` tools to run KQL.

Verify with:

```bash
bash scripts/check-sre-agent.sh
# Look for the two new entries under "Data connectors currently on $AGENT_NAME".
```

In chat, try:

```
/agent reliability-fixer
Pull the last 24h of dependency failures for {YOUR_APP_INSIGHTS}, grouped by target.
```

If that returns rows, the wiring is good.

---

## 4. What each subagent consumes

The subagent YAMLs in `subagents/` declare their tools, but here's what they actually **need** in the LAW/AppI for the runbooks to fire correctly. Use this as a check-list when seeding diagnostic settings.

| Subagent | LAW tables it queries | App Insights tables | Without these it falls back to … |
|---|---|---|---|
| `security-fixer` | `AzureDiagnostics` (NSG flow, KV audit), `AzureActivity`, `SecurityAlert` | — | `az` reads only — slower, no history |
| `reliability-fixer` | `AzureMetrics`, `AzureDiagnostics` (KV cert events), `AzureActivity` | `dependencies`, `exceptions`, `requests` | metric snapshots only |
| `cost-optimizer` | `AzureMetrics` (CPU/mem 14d), `Usage` (LAW ingest itself) | — | Azure Advisor / pricing-page lookups |
| `code-analyzer` | (none — reads source via GitHub connector) | (none) | — |
| `issue-triager` | (none) | (none) | runbook-only classification |

**Practical implication:** if you only do *one* thing, turn on diagnostic settings for **NSGs, Key Vaults, App Services, Storage Accounts, and your Azure OpenAI resource**. Those cover ~90 % of the runbooks in this kit.

### Recommended LAW tables to confirm are receiving data

After ~30 min of activity, you should see:

```kusto
union withsource = TableName *
| where TimeGenerated > ago(1h)
| summarize Rows = count() by TableName
| order by Rows desc
```

Expected non-zero rows in: `AzureActivity`, `AzureDiagnostics` (or per-resource tables like `AzureMetrics`, `KeyVaultAuditEvent`, `AppServiceHTTPLogs`), and (if app is wired) `AppRequests`, `AppDependencies`, `AppExceptions`, `AppTraces`.

---

## 5. App-side telemetry (Python / Node / .NET)

If your IaC repo is a deployed app (the triage workflow itself, or a workload the SRE Agent monitors), you can also emit OpenTelemetry to App Insights. The recommended path in 2026 is the **Azure Monitor OpenTelemetry distro**, not the legacy instrumentation keys.

### Python (Flask / FastAPI / generic)

```bash
pip install azure-monitor-opentelemetry
```

```python
# at process startup, BEFORE app creation
import os
from azure.monitor.opentelemetry import configure_azure_monitor

if os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    configure_azure_monitor()
```

That single call auto-instruments Flask/FastAPI, outbound `requests`/`httpx`, and exceptions. The triage agent in this kit does exactly this — see [`skills/issue-triage/triage_agent/main.py`](../skills/issue-triage/triage_agent/main.py).

### Node

```bash
npm install @azure/monitor-opentelemetry
```

```javascript
// load BEFORE other modules
const { useAzureMonitor } = require('@azure/monitor-opentelemetry');
if (process.env.APPLICATIONINSIGHTS_CONNECTION_STRING) {
  useAzureMonitor();
}
```

### Sampling

For high-volume apps, set head-based sampling at the distro level rather than per-span:

```python
configure_azure_monitor(
    sampling_ratio=0.1,   # keep 10 % of telemetry
)
```

Or via env var (works for both Python and Node distros): `OTEL_TRACES_SAMPLER_ARG=0.1`.

---

## 6. Cost guardrails

These three settings keep telemetry from becoming a surprise bill:

1. **LAW daily cap** — `--daily-quota-gb 5` on the workspace. Ingestion hard-stops at the cap until UTC midnight.
2. **App Insights ingestion sampling** — set via the distro's `sampling_ratio` (see §5). Drop noisy `requests` and `dependencies` first.
3. **Diagnostic settings discipline** — don't enable `allLogs` on resource types that emit verbose data (Storage, AKS) unless you have a budget for it. Use named log categories instead. The policies in this kit use `audit` + `allMetrics` by default for that reason.

For ongoing cost visibility:

```kusto
// LAW: who's eating the ingestion budget?
Usage
| where TimeGenerated > ago(7d)
| where IsBillable
| summarize GB = sum(Quantity) / 1000 by DataType
| order by GB desc
```

---

## 7. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Connector created but `QueryLogAnalyticsByWorkspaceId` returns `Forbidden` | UAMI missing `Log Analytics Reader` on the LAW's RG | re-run `bash scripts/apply-sre-config.sh --with-app-telemetry` |
| App Insights connector created but no data | Classic (non-workspace) App Insights | migrate: `az monitor app-insights component update -a $APPI_NAME -g $TEL_RG --workspace $LAW_ID` |
| LAW returns no rows from `AzureDiagnostics` | Diagnostic settings not configured on the resources | apply the policy initiative in `policies/initiatives/sre-agent-telemetry-baseline.json` |
| Subagent says "no recent activity" but the resource is active | Metrics-only resource (e.g. some PaaS); subagent expected diagnostic logs | check the resource's "Diagnostic settings" blade — confirm `allMetrics` is on |
| App Insights tables (`AppRequests` etc.) empty | Distro not initialised OR connection string missing in app config | confirm `APPLICATIONINSIGHTS_CONNECTION_STRING` is set in the app's env; call `configure_azure_monitor()` once at startup |

---

## What to read next

- [`policy-enforcement.md`](policy-enforcement.md) — make the diagnostic-settings setup self-enforcing instead of manual per resource
- [`agent-design.md`](agent-design.md) — what the triage agent does with this telemetry
- [`scenarios.md`](scenarios.md) — the four broken-on-purpose patterns each subagent investigates
