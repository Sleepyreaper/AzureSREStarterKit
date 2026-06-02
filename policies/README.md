# Policies

Copy-paste Azure Policy definitions that make the diagnostic settings + tag conventions the SRE Agent runbooks rely on **self-enforcing** instead of manual per-resource.

```
diagnostic-settings/
  keyvault-to-law.json         DINE: send KV audit + allLogs to your LAW
  nsg-to-law.json              DINE: send NSG events to your LAW
  azure-openai-to-law.json     DINE: send Azure OpenAI Audit/RequestResponse/Trace to your LAW

tagging/
  require-support-owner-tag.json   Audit (or Deny) resources missing 'support-owner' tag

initiatives/
  sre-agent-telemetry-baseline.json   Bundles all four above into one assignable initiative
```

**Read this first:** [`../docs/policy-enforcement.md`](../docs/policy-enforcement.md) — full deploy + assign + remediate walkthrough with `az` commands.

For the underlying telemetry backend (LAW + App Insights), see [`../docs/telemetry-setup.md`](../docs/telemetry-setup.md).

## Extending

Each `diagnostic-settings/*.json` is the same shape: change the `if.field.equals` resource type, the two ARM template `type`s, and the `logs[]` categories. The role IDs (`Log Analytics Contributor` + `Monitoring Contributor`) work for any resource type. See the "Per-resource-type expansion pattern" section of `policy-enforcement.md` for the recipe.
