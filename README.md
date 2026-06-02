# Azure SRE Agent Starter Kit

A copy-paste starter kit for the [**Azure SRE Agent**](https://sre.azure.com).

Today there is **no first-party way to deploy an Azure SRE Agent's subagents, prompts, or runbooks as code**. The agent and its extensions are configured in the portal at https://sre.azure.com. This repo gives you everything you need to do that configuration in minutes instead of days, by sharing the YAML, prompts, and runbooks we use in production-style demos.

## What's in the box

```
subagents/                          # 5 subagent specs — paste into Agent Canvas
  security-fixer.yaml               #   investigates NSG / encryption / public-exposure drift
  reliability-fixer.yaml            #   finds availability gaps (autoscale, capacity, SLO)
  cost-optimizer.yaml               #   finds waste (oversized VMs, orphaned disks, idle APIM)
  code-analyzer.yaml                #   reads the IaC repo, cross-references findings
  issue-triager.yaml                #   autonomous classify/label/route on inbound GitHub issues

knowledge-base/                     # 6 runbooks the SRE Agent indexes
  security-drift-runbook.md
  reliability-runbook.md
  cost-waste-runbook.md
  storm-readiness-runbook.md
  github-issue-triage.md
  incident-report-template.md
  example-environment-architecture.md

skills/issue-triage/                # Close the loop: SRE Agent files issue → Action drafts PR
  workflow.yml                      #   GitHub Action trigger
  triage-action/                    #   Python that reads the agent's issue and proposes a code fix

scripts/                            # Helpers (bash) for repeatable config
  apply-sre-config.sh               # Index knowledge base, wire CodeRepo + telemetry connectors, grant RBAC
  register-github-repo.sh           # Register a GitHub repo as a CodeRepo (after OAuth)
  check-sre-agent.sh                # Health probe — endpoint, KG state, subagent count
  simulate-sre-issue.sh             # Fire a test investigation thread
  seed-expiring-cert.sh             # Plant a "near-expiry" Key Vault cert for reliability demos

docs/
  subagent-paste-cheatsheet.md      # ⭐ The 10-min portal walkthrough
  applying-subagents-via-portal.md  # Deeper guide on Agent Canvas mechanics
  agent-design.md                   # Why these 5 subagents, why this division of labor
  azure-sre-resources.md            # Links to every public Azure SRE Agent doc + blog
  scenarios.md                      # Demoable IT-ops scenarios you can deploy on top
```

## Quick start

1. **Create an SRE Agent** at https://sre.azure.com (Standard plan). Pick a name, scope it to your resource group(s), set action mode to **review** for safety.
2. **OAuth your GitHub** in the agent's CodeRepo settings, then register your IaC repo.
3. **Run** `scripts/apply-sre-config.sh` against your agent — it indexes the runbooks, grants RBAC, and (optionally) wires Application Insights + Log Analytics connectors.
4. **Open Agent Canvas** in the portal and paste each subagent from `docs/subagent-paste-cheatsheet.md` (one per agent — Name, Mode, Handoff, Tools, system prompt).
5. **Drop the triage workflow** in your repo at `.github/workflows/issue-triage.yml` (copy from `skills/issue-triage/`).
6. **Smoke test** with `/agent security-fixer` in a fresh thread, or run `scripts/simulate-sre-issue.sh`.

## Placeholders

The YAML and scripts use these placeholders — replace before pasting:

| Placeholder | Replace with |
|---|---|
| `{YOUR_RG}` | Resource group(s) the agent monitors |
| `{YOUR_SRE_AGENT_NAME}` | Your SRE Agent resource name |
| `{YOUR_SUBSCRIPTION_ID}` | Your Azure subscription |
| `{GITHUB_OWNER}` / `{GITHUB_REPO}` | Your IaC repo coordinates |
| `{PROTECTED_RESOURCE}` | Any resource the agent must NOT modify (e.g. Foundry account) |
| `YOUR_APP_INSIGHTS` / `YOUR_LOG_ANALYTICS_WS` | If wiring app telemetry connectors |
| `{YOUR_ORG}` / `{CUSTOMER_RG}` | Branding / multi-tenant naming |

## Why this exists

The Azure SRE Agent's value is in its **investigation playbooks** — the system prompts, the knowledge base it queries, and the way subagents hand off work to each other. None of that is shipped or templated by default. This kit captures one working configuration so others don't start from a blank canvas.

PRs welcome — especially new subagents and runbooks for other scenarios (databases, network egress, FinOps tagging, etc.).

## License

MIT — see [LICENSE](LICENSE).
