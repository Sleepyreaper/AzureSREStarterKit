# Azure SRE Agent Starter Kit

A copy-paste starter kit for the [**Azure SRE Agent**](https://aka.ms/sreagent).

Today there is **no first-party way to deploy an Azure SRE Agent's subagents, prompts, or runbooks as code**. The agent and its extensions are configured in the portal at https://sre.azure.com. This repo gives you everything you need to do that configuration in minutes instead of days, by sharing the YAML, prompts, and runbooks we use in production-style demos.

## What's in the box

### [`subagents/`](subagents/) — 5 subagent specs (paste into Agent Canvas)

- [`security-fixer.yaml`](subagents/security-fixer.yaml) — investigates NSG / encryption / public-exposure drift
- [`reliability-fixer.yaml`](subagents/reliability-fixer.yaml) — finds availability gaps (autoscale, capacity, certs)
- [`cost-optimizer.yaml`](subagents/cost-optimizer.yaml) — finds waste (oversized VMs, orphaned disks, idle plans)
- [`code-analyzer.yaml`](subagents/code-analyzer.yaml) — reads the IaC repo, cross-references findings
- [`issue-triager.yaml`](subagents/issue-triager.yaml) — autonomous classify/label/route on inbound GitHub issues

### [`knowledge-base/`](knowledge-base/) — 7 runbooks the SRE Agent indexes

- [`security-drift-runbook.md`](knowledge-base/security-drift-runbook.md)
- [`reliability-runbook.md`](knowledge-base/reliability-runbook.md)
- [`cost-waste-runbook.md`](knowledge-base/cost-waste-runbook.md)
- [`storm-readiness-runbook.md`](knowledge-base/storm-readiness-runbook.md)
- [`github-issue-triage.md`](knowledge-base/github-issue-triage.md)
- [`incident-report-template.md`](knowledge-base/incident-report-template.md)
- [`example-environment-architecture.md`](knowledge-base/example-environment-architecture.md)

### [`skills/issue-triage/`](skills/issue-triage/) — close the loop: SRE Agent files issue → Action drafts PR

- [`workflow.yml`](skills/issue-triage/workflow.yml) — copy to `.github/workflows/issue-triage.yml` in your IaC repo
- [`triage_agent/`](skills/issue-triage/triage_agent/) — Python package the workflow runs (reads the issue, calls Azure OpenAI, writes a PR body)
- [`README.md`](skills/issue-triage/README.md) — install + secrets checklist

### [`scripts/`](scripts/) — helpers (bash) for repeatable config

- [`apply-sre-config.sh`](scripts/apply-sre-config.sh) — index the knowledge base, register your IaC repo as a CodeRepo, grant the agent's UAMI Reader / Monitoring Reader / LAW Reader on `RG`, and (optionally) wire Application Insights + Log Analytics connectors
- [`register-github-repo.sh`](scripts/register-github-repo.sh) — register a single GitHub repo as a CodeRepo (after you've signed into GitHub at https://sre.azure.com once)
- [`check-sre-agent.sh`](scripts/check-sre-agent.sh) — health probe: endpoint, KG state, subagent count, UAMI RBAC, required GitHub secrets
- [`simulate-sre-issue.sh`](scripts/simulate-sre-issue.sh) — file a synthetic SRE-style issue to exercise the triage loop without waiting for a real finding
- [`seed-expiring-cert.sh`](scripts/seed-expiring-cert.sh) — plant a "near-expiry" Key Vault cert for reliability demos

### [`docs/`](docs/)

- [`subagent-paste-cheatsheet.md`](docs/subagent-paste-cheatsheet.md) — ⭐ the 10-min portal walkthrough; one block per subagent ready to paste
- [`applying-subagents-via-portal.md`](docs/applying-subagents-via-portal.md) — deeper guide on Agent Canvas mechanics
- [`agent-design.md`](docs/agent-design.md) — why a single triage agent (not a council), and how it's wired
- [`telemetry-setup.md`](docs/telemetry-setup.md) — ⭐ Log Analytics + App Insights wiring; what each subagent actually reads
- [`policy-enforcement.md`](docs/policy-enforcement.md) — Azure Policy guide for auto-wiring diagnostic settings + enforcing tags
- [`azure-sre-resources.md`](docs/azure-sre-resources.md) — curated index of every public Azure SRE Agent doc + blog
- [`scenarios.md`](docs/scenarios.md) — four broken-on-purpose patterns that pair with the runbooks
- [`wif-setup.md`](docs/wif-setup.md) — step-by-step Workload Identity Federation setup for the triage workflow

### [`policies/`](policies/) — copy-paste Azure Policy JSON

Four custom policies + an initiative that make the telemetry/tagging the runbooks rely on self-enforcing. See [`docs/policy-enforcement.md`](docs/policy-enforcement.md) for the assignment recipe.

## Quick start

```bash
# 0. Sign in to Azure and create / pick your SRE Agent
az login
# Portal: https://sre.azure.com → New SRE Agent → pick a name, scope to your RG, action mode = Review

# 1. Stand up the telemetry backend (Log Analytics Workspace + App Insights)
#    See docs/telemetry-setup.md for the full why/how; then come back here.

# 2. (Strongly recommended) Make diagnostic settings + tagging self-enforcing
#    See docs/policy-enforcement.md — assigns one initiative that wires every
#    new KV/NSG/OpenAI resource to your LAW automatically.

# 3. Run the one-shot configurator
export RG=rg-your-monitored-rg
export AGENT_NAME=your-sre-agent
export GITHUB_REPO=owner/your-iac-repo
export LOG_ANALYTICS_ID=/subscriptions/…/workspaces/your-law
export APP_INSIGHTS_ID=/subscriptions/…/components/your-appi
bash scripts/apply-sre-config.sh --with-app-telemetry

# 4. Paste the 5 subagents into Agent Canvas — follow docs/subagent-paste-cheatsheet.md
#    (the data-plane subagent API is gated to internal tenants today; the portal isn't)

# 5. Wire the triage skill into your IaC repo
#    Copy skills/issue-triage/workflow.yml → .github/workflows/issue-triage.yml
#    Copy skills/issue-triage/triage_agent/ → .github/triage_agent/
#    Set the GitHub secrets per docs/wif-setup.md

# 6. Smoke test
bash scripts/check-sre-agent.sh
bash scripts/simulate-sre-issue.sh "Open NSG rule on web-nsg" security web-nsg "$RG"
```

`scripts/apply-sre-config.sh` is idempotent — re-run it after every knowledge-base edit to re-index.

## Placeholders

The YAML, runbooks, and scripts use these placeholders — replace before pasting (or set as env vars for the scripts):

| Placeholder | Replace with |
|---|---|
| `{YOUR_RG}` | Resource group the agent monitors |
| `{YOUR_SRE_AGENT_NAME}` | Your SRE Agent resource name |
| `{YOUR_SUBSCRIPTION_ID}` | Your Azure subscription |
| `{YOUR_REGION}` | Azure region of the monitored RG (e.g. `eastus2`) |
| `{GITHUB_OWNER}` / `{GITHUB_REPO}` | Your IaC repo coordinates |
| `{PROTECTED_RESOURCE}` | Any resource the agent must NOT modify (e.g. a Foundry account) |
| `{YOUR_ORG}` | Branding string used in agent comment headers |
| `{CUSTOMER_RG}` | (Optional) second RG for multi-tenant / Lighthouse demos |
| `TRIAGE_DEPLOYMENT` | Azure OpenAI **deployment name** the triage workflow calls (not a model name; e.g. `gpt-4o-mini`) |

## Why this exists

The Azure SRE Agent's value is in its **investigation playbooks** — the system prompts, the knowledge base it queries, and the way subagents hand off work to each other. None of that is shipped or templated by default. This kit captures one working configuration so others don't start from a blank canvas.

PRs welcome — especially new subagents and runbooks for other scenarios (databases, network egress, FinOps tagging, etc.). See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
