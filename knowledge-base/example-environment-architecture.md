# {YOUR_RG} — Solution Architecture (Template)

> Knowledge base entry loaded into Azure SRE Agent (`{YOUR_SRE_AGENT_NAME}`). Gives the agent the operational context it needs to triage findings in this resource group. **Replace placeholders before uploading.**

## Operational context

`{YOUR_RG}` is the resource group `{YOUR_SRE_AGENT_NAME}` monitors in subscription `{YOUR_SUBSCRIPTION_ID}` (region `{YOUR_REGION}`). The agent demonstrates an end-to-end agentic operations loop:

- **detection** — SRE Agent's own knowledge graph + Azure Monitor signals
- **triage** — custom subagents (`security-fixer`, `cost-optimizer`, `reliability-fixer`, `code-analyzer`) using runbooks in this knowledge base
- **proposal** — GitHub issues opened on `{GITHUB_OWNER}/{GITHUB_REPO}`
- **human approval** — PR review + merge gate (handled by the triage workflow in `skills/issue-triage/`)
- **deployment** — your own GitHub Actions deploy pipeline applies the merged fix back to `{YOUR_RG}`

## Tag conventions (recommended)

Tagging every resource the agent might investigate is the single highest-leverage thing you can do to improve triage quality. The subagents look for these tags first:

| Tag | Purpose | Example value |
|---|---|---|
| `owner` | Who to notify when something breaks | `team-platform@example.com` |
| `criticality` | Blast-radius hint | `tier-1` / `tier-2` / `tier-3` / `demo` |
| `cost-center` | Cost-optimizer routes findings here | `cc-12345` |
| `scenario` | (Optional) maps the resource to a specific known pattern, useful when you've intentionally seeded broken-on-purpose resources for demos | `storm-no-autoscale` |
| `expected-finding` | (Optional) lets the agent sanity-check its diagnosis against the resource's intended state | `vmss-no-autoscale-rules` |

When investigating, **always read the tags first** — they tell you what the resource is, who owns it, and (if seeded) what it's supposed to demonstrate.

## Resource inventory (example — adapt to your environment)

Replace this table with your actual inventory. Pattern: name · type · purpose · notes.

| Resource | Type | Purpose | Notes |
|---|---|---|---|
| `<vmss-name>` | `Microsoft.Compute/virtualMachineScaleSets` | Customer-facing tier | Watch for missing autoscale settings |
| `<vnet-name>` | `Microsoft.Network/virtualNetworks` | Hosts compute subnets | |
| `<nsg-name>` | `Microsoft.Network/networkSecurityGroups` | Inbound traffic policy | Audit `0.0.0.0/0` source rules monthly |
| `<disk-name>` | `Microsoft.Compute/disks` | Premium SSD for `<vmss-name>` | Watch for `Unattached` state >7 days |
| `<kv-name>` | `Microsoft.KeyVault/vaults` | TLS certs, app secrets | Watch for certs expiring within 30 days |
| `{PROTECTED_RESOURCE}` | varies | Production resource the agent **must not modify** | Listed for awareness; out of scope for any write actions |

## Investigation patterns

When you find an issue in `{YOUR_RG}`:

1. **Read the tags.** `criticality` tells you how loud to be; `owner` tells you who to notify; `expected-finding` (if present) tells you whether the issue is a known/intentional state.
2. **Search the knowledge base for the matching scenario runbook** (e.g., open NSG rule → `security-drift-runbook.md`).
3. **Follow the runbook** end-to-end. Don't skip diagnostic steps.
4. **File a GitHub issue** on `{GITHUB_OWNER}/{GITHUB_REPO}` using `incident-report-template.md`. Always include full ARM resource IDs in the References section.
5. **Never write to resources outside `{YOUR_RG}`** — your scope is bounded by the agent's knowledge-graph configuration.

## Human-in-the-loop boundary

Each subagent has an `agent_type`. For this starter kit:

- `code-analyzer`, `cost-optimizer`, `security-fixer`, `reliability-fixer` — **Review** mode (propose only; humans approve via PR)
- `issue-triager` — **Autonomous** (labels and comments on issues without approval; cannot modify code or Azure)

Never escalate a Review-mode subagent to Autonomous mode without explicit human authorization.
