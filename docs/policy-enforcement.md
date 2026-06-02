# Policy Enforcement — Telemetry, Diagnostics, and Tagging

The SRE Agent and the subagents in this kit are only as good as the data they can see. Setting **diagnostic settings** per resource by hand drifts immediately — someone creates a new Key Vault, forgets to wire it, and the next finding has no audit log to root-cause from.

**Azure Policy** fixes this. Assign the policies below at subscription or management-group scope, and Azure will auto-attach diagnostic settings to every new (and existing, if you remediate) resource of the targeted type.

This kit ships **four custom policies** + **one initiative** that bundles them. They're intentionally minimal and copy-paste ready. Extend per-resource-type by following the same pattern.

| File | What it does |
|---|---|
| [`diagnostic-settings/keyvault-to-law.json`](../policies/diagnostic-settings/keyvault-to-law.json) | DINE: send Key Vault audit + allLogs to your LAW |
| [`diagnostic-settings/nsg-to-law.json`](../policies/diagnostic-settings/nsg-to-law.json) | DINE: send NSG event + rule-counter logs to your LAW |
| [`diagnostic-settings/azure-openai-to-law.json`](../policies/diagnostic-settings/azure-openai-to-law.json) | DINE: send Azure OpenAI Audit/RequestResponse/Trace + metrics to your LAW |
| [`tagging/require-support-owner-tag.json`](../policies/tagging/require-support-owner-tag.json) | Audit (or Deny) resources missing a `support-owner` tag — runbooks rely on this |
| [`initiatives/sre-agent-telemetry-baseline.json`](../policies/initiatives/sre-agent-telemetry-baseline.json) | Initiative bundling all four above |

> **Why custom, not built-in?** Microsoft ships built-in DINE policies for most resource types already (search "Configure Microsoft.X to use diagnostic settings" in the portal). They're great. The custom ones here are versioned alongside the runbooks they serve, so when a runbook needs a new log category, the policy moves with it. If you'd rather use Microsoft's built-ins, see the cross-reference table at the end of this doc.

---

## What "DINE" means and why it works

`DeployIfNotExists` (DINE) is the policy effect that says: *"if a resource of type X doesn't have child resource Y, deploy Y."* It runs at evaluation time on every resource create/update, plus on a daily compliance sweep, plus on-demand via a **remediation task**.

For diagnostic settings:

```
Resource (e.g. KV)  ──► policy evaluates  ──► no diagnostic settings? ──► deploys one
                                          └─► already wired?           └─► skip
```

The policy assignment creates a **managed identity** at assignment time. That identity does the deployment. The policy spec lists the role definition IDs it needs (`Log Analytics Contributor` + `Monitoring Contributor`); the platform grants those automatically *only* at the assigned scope.

---

## Quick start — deploy the initiative

### 0. Prerequisites

- An existing **Log Analytics Workspace** — see [`telemetry-setup.md §2`](telemetry-setup.md#2-create-the-backend-resources)
- Permission to write policy definitions at your target scope: `Resource Policy Contributor` or `Owner` at subscription / management group

### 1. Set variables

```bash
SUB=$(az account show --query id -o tsv)
SCOPE="/subscriptions/${SUB}"          # or /providers/Microsoft.Management/managementGroups/your-mg
LAW_ID="/subscriptions/$SUB/resourceGroups/rg-shared-telemetry/providers/Microsoft.OperationalInsights/workspaces/law-shared-…"
LOC=eastus2
```

### 2. Create the policy definitions

```bash
cd policies

KV_ID=$(az policy definition create \
  --name sre-diag-keyvault-to-law \
  --display-name "Deploy Diagnostic Settings for Key Vault to LAW" \
  --rules diagnostic-settings/keyvault-to-law.json \
  --mode Indexed \
  --query id -o tsv)

NSG_ID=$(az policy definition create \
  --name sre-diag-nsg-to-law \
  --display-name "Deploy Diagnostic Settings for NSGs to LAW" \
  --rules diagnostic-settings/nsg-to-law.json \
  --mode Indexed \
  --query id -o tsv)

OAI_ID=$(az policy definition create \
  --name sre-diag-openai-to-law \
  --display-name "Deploy Diagnostic Settings for Azure OpenAI to LAW" \
  --rules diagnostic-settings/azure-openai-to-law.json \
  --mode Indexed \
  --query id -o tsv)

TAG_ID=$(az policy definition create \
  --name sre-require-support-owner-tag \
  --display-name "Require 'support-owner' tag on all resources" \
  --rules tagging/require-support-owner-tag.json \
  --mode Indexed \
  --query id -o tsv)

echo "KV_ID=$KV_ID"
echo "NSG_ID=$NSG_ID"
echo "OAI_ID=$OAI_ID"
echo "TAG_ID=$TAG_ID"
```

> The four `*.json` files in this repo are the **full ARM policy bodies** (`{"properties": {...}}`). `az policy definition create --rules` accepts either the full body or just the `properties.policyRule` section; if `az` complains, pass `--params` and `--description` separately or use `az rest` with the raw JSON.

### 3. Patch the initiative with the real definition IDs

The initiative file ships with `REPLACE_WITH_*` placeholders so it can be version-controlled. Generate a populated copy:

```bash
sed \
  -e "s|REPLACE_WITH_KEYVAULT_POLICY_DEFINITION_ID|${KV_ID}|" \
  -e "s|REPLACE_WITH_NSG_POLICY_DEFINITION_ID|${NSG_ID}|" \
  -e "s|REPLACE_WITH_OPENAI_POLICY_DEFINITION_ID|${OAI_ID}|" \
  -e "s|REPLACE_WITH_SUPPORT_OWNER_TAG_POLICY_DEFINITION_ID|${TAG_ID}|" \
  initiatives/sre-agent-telemetry-baseline.json \
  > /tmp/sre-baseline-resolved.json

az policy set-definition create \
  --name sre-agent-telemetry-baseline \
  --display-name "SRE Agent — Telemetry Baseline" \
  --definitions "$(jq -c .properties.policyDefinitions /tmp/sre-baseline-resolved.json)" \
  --params "$(jq -c .properties.parameters /tmp/sre-baseline-resolved.json)"
```

### 4. Assign the initiative

```bash
az policy assignment create \
  --name sre-telemetry-baseline \
  --display-name "SRE Agent telemetry baseline" \
  --policy-set-definition sre-agent-telemetry-baseline \
  --scope "$SCOPE" \
  --location "$LOC" \
  --mi-system-assigned \
  --params "{\"logAnalyticsWorkspaceId\":{\"value\":\"$LAW_ID\"}}"
```

The `--mi-system-assigned --location $LOC` flags create the managed identity that the DINE deployments run as. The platform auto-grants `Log Analytics Contributor` + `Monitoring Contributor` at the assigned scope. If the assignment hangs on "permissions pending", wait ~5 min for the role assignment to propagate.

### 5. Remediate existing resources

By default, DINE only fires on **new** resources. To wire existing ones:

```bash
ASSIGN_ID=$(az policy assignment show -n sre-telemetry-baseline --scope "$SCOPE" --query id -o tsv)

# One remediation task per policy in the initiative
for REF_ID in diagKeyVault diagNsg diagOpenAi; do
  az policy remediation create \
    -n "remediate-${REF_ID}-$(date +%s)" \
    --policy-assignment "$ASSIGN_ID" \
    --definition-reference-id "$REF_ID" \
    --resource-discovery-mode ReEvaluateCompliance
done
```

Watch progress:

```bash
az policy remediation list --query "[].{name:name, state:provisioningState, success:deploymentSummary.successfulDeployments, total:deploymentSummary.totalDeployments}" -o table
```

### 6. Verify

After ~30 minutes:

```bash
# Compliance summary — should trend toward 100% as remediation completes
az policy state summarize \
  --policy-set-definition sre-agent-telemetry-baseline \
  --output table

# Spot-check one resource
az monitor diagnostic-settings list \
  --resource "$(az keyvault list --query '[0].id' -o tsv)" \
  -o table
```

You should see one diagnostic setting named `to-shared-law` pointed at your LAW.

---

## Tag policy: from Audit to Deny

`require-support-owner-tag.json` ships with `effect: Audit` so it doesn't break existing resources. Workflow:

1. **Assign with Audit.** Wait a day. Run `az policy state list --query "[?complianceState=='NonCompliant'].{r:resourceId}" -o tsv` — get the list of resources missing the tag.
2. **Backfill tags.** `for R in $(...); do az tag update --resource-id "$R" --operation merge --tags support-owner=team-platform@example.com; done`
3. **Flip to Deny.** Re-assign with `--params "{\"effect\":{\"value\":\"Deny\"}}"`. From this point any resource creation without the tag is rejected by ARM.

Same pattern works for `criticality`, `cost-center`, or any tag your runbooks rely on. Duplicate the JSON, change `tagName`'s `defaultValue`, and create a new definition.

---

## Per-resource-type expansion pattern

The three `diagnostic-settings/*.json` files all follow the same shape. To add a new resource type (e.g. App Service):

1. Copy `keyvault-to-law.json` to `appservice-to-law.json`.
2. Replace `Microsoft.KeyVault/vaults` (4 occurrences — `policyRule.if.field.equals`, two template `type`s, and the displayName) with `Microsoft.Web/sites`.
3. Look up the resource-type's diagnostic categories — easiest with: `az monitor diagnostic-settings categories list --resource $(az webapp list --query '[0].id' -o tsv) -o table`. Edit the `logs` array accordingly.
4. Re-create the policy: `az policy definition create -n sre-diag-appservice-to-law --rules appservice-to-law.json --mode Indexed`.
5. Add it to the initiative.

The same `roleDefinitionIds` work for any resource type — those are the *generic* Log Analytics + Monitoring contributor roles, not resource-specific.

---

## Cross-reference: Microsoft built-in alternatives

If you prefer Microsoft-maintained policies over the custom ones here, the built-ins are listed below. Use `az policy definition list --query "[?contains(displayName, 'diagnostic')].{name:name, dn:displayName}" -o table` to find their exact IDs.

| Built-in | Equivalent custom in this kit |
|---|---|
| `Configure diagnostic settings for Azure Key Vault to Log Analytics workspace` | `keyvault-to-law.json` |
| `Deploy Diagnostic Settings for Network Security Groups` (deprecates to `Configure ...`) | `nsg-to-law.json` |
| `Configure Cognitive Services accounts to send diagnostics to Log Analytics workspace` | `azure-openai-to-law.json` (built-in is generic to all Cognitive Services; custom is OpenAI-scoped) |
| `Require a tag and its value on resources` | `require-support-owner-tag.json` (custom is simpler — audit-only on tag presence, no value check) |
| `Enable Azure Monitor for VMs / VMSS / Arc` | Add separately; not in this initiative because VM-AMA setup needs a DCR + DCRA that's environment-specific |

Microsoft also ships an **initiative** called **"Configure Azure Defender to be enabled"** which is worth assigning alongside this one — Defender findings land in `SecurityAlert` and the `security-fixer` subagent will use them automatically.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Could not get policy definition` when running `az policy assignment create` | Definition was created at a different scope than where you're trying to assign | Pass `--policy <full-resource-id-of-definition>` instead of just the name |
| Initiative assignment hangs in `Pending` for >10 min | Managed identity role propagation lag | Wait. If still pending after 30 min, recreate with `--mi-system-assigned` and re-check the role assignment exists at `$SCOPE` |
| Remediation task succeeds but no diagnostic setting appears | The `existenceCondition` matched a different existing setting | Check the resource — there's probably an old setting pointing at a different LAW. Either delete it or change the policy's `diagnosticSettingName` |
| `Forbidden` from policy on Cognitive Services | OpenAI resources can need data-plane RBAC too | Most diagnostic settings work with the control-plane role only; if you hit this on RequestResponse logs, also grant `Cognitive Services Contributor` |
| Compliance shows 100 % but the SRE Agent says it can't query LAW | Connector not wired on the agent | Re-run `bash scripts/apply-sre-config.sh --with-app-telemetry` |

---

## What to read next

- [`telemetry-setup.md`](telemetry-setup.md) — the LAW + App Insights side of the equation
- [`agent-design.md`](agent-design.md) — what subagents do with the data you're now collecting
