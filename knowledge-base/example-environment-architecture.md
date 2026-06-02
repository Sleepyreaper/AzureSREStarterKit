# {YOUR_RG} — Solution Architecture

> Knowledge base entry loaded into Azure SRE Agent (`{YOUR_SRE_AGENT_NAME}`). Provides the agent with the operational context it needs to triage findings in this resource group.

## Operational context

`{YOUR_RG}` is a demo / showcase environment in subscription `{YOUR_SUBSCRIPTION_ID}` (region `eastus2`). It deliberately contains broken-on-purpose resources so the Azure SRE Agent can demonstrate end-to-end agentic operations:

- **detection** (SRE Agent's own knowledge graph + Azure Monitor signals)
- **triage** (custom subagents using runbooks in this knowledge base)
- **proposal** (GitHub issues opened on `{GITHUB_OWNER}/{GITHUB_REPO}`)
- **human approval** (PR review + merge gate)
- **deployment** (GitHub Actions redeploys the fixed scenario back to `{YOUR_RG}`)

## Tag conventions

Every demo resource carries these tags:

| Tag | Purpose |
|---|---|
| `scenario` | One of: `storm-no-autoscale`, `security-open-ssh`, `cost-orphaned-resources`, `reliability-cert-expiry` |
| `support-owner` | Email of the team that owns the resource (always `demo-team@example.com` here) |
| `expected-finding` | What this resource is supposed to demonstrate when broken |
| `simulates` | What real-world infrastructure pattern this represents in a real environment |

When investigating, **always read the tags first** — they tell you what the resource is supposed to demonstrate. If `expected-finding` matches your independent assessment, you're on the right track.

## Resource inventory

| Resource | Type | Scenario | Notes |
|---|---|---|---|
| `ogedemo-storm-vmss` | `Microsoft.Compute/virtualMachineScaleSets` | storm | No autoscale settings; capacity locked at 1. Simulates a customer-portal tier. |
| `ogedemo-storm-vnet` | `Microsoft.Network/virtualNetworks` | storm | Hosts the VMSS subnet. |
| `ogedemo-security-nsg` | `Microsoft.Network/networkSecurityGroups` | security | Has Allow inbound for ports 22 and 3389 from `0.0.0.0/0`. |
| `ogedemo-cost-orphan-disk` | `Microsoft.Compute/disks` | cost | 1 TB Premium SSD, unattached. ~$135/month wasted. |
| `ogedemo-cost-orphan-pip` | `Microsoft.Network/publicIPAddresses` | cost | Standard SKU static IP, no association. |
| `ogekv...` (random suffix) | `Microsoft.KeyVault/vaults` | reliability | Contains `near-expiry-cert` (30-day validity, no rotation policy). |
| `{PROTECTED_RESOURCE}` | `Microsoft.CognitiveServices/accounts` | (production) | Azure AI Foundry project that hosts agents for the sister Cloud Weather Operations platform app. **Do not break this.** |

## Companion app: sister Cloud Weather Operations platform

A separate Flask app at `https://cwo.example.com` runs an interactive multi-agent debate UI on top of the same Foundry account (`{PROTECTED_RESOURCE}`). It is **not** a target for SRE Agent action — it is a sibling system that demonstrates a different agentic pattern (synchronous chat with a 6-agent council).

## Investigation patterns

When you find an issue in `{YOUR_RG}`:

1. **Read the tags.** The `expected-finding` tag tells you what the resource is supposed to demonstrate. If your analysis matches, great. If not, dig deeper.
2. **Check `support-owner`.** Route findings to that email.
3. **Search the knowledge base for the matching scenario runbook** (e.g., `security-open-ssh` → `security-drift-runbook.md`).
4. **Follow the runbook** end-to-end. Don't skip steps.
5. **File a GitHub issue** on `{GITHUB_OWNER}/{GITHUB_REPO}` using the incident report template.
6. **Never write to resources outside `{YOUR_RG}`** — your scope is bounded.

## Human-in-the-loop boundary

Your agent's `agent_type` is configured per subagent. For this showcase:

- `code-analyzer`, `cost-optimizer`, `security-fixer`, `reliability-fixer` — **Review** mode (propose only, humans approve via PR)
- `issue-triager` — **Autonomous** (labels and comments on issues without approval)

Never escalate to Autonomous mode without explicit human authorization.
