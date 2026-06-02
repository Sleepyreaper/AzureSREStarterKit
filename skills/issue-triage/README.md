# Issue Triage Skill

A GitHub Actions skill that closes the loop between a finding filed by Azure SRE Agent and a draft pull request a human can review.

```
Azure SRE Agent finds drift in your resource group
        │
        ▼  files an issue with label `sre-finding`
GitHub Issue
        │
        ▼  workflow fires
.github/workflows/issue-triage.yml
        │
        ▼  python -m triage_agent
Azure OpenAI (your deployment)
        │
        ▼  returns JSON proposal
out/proposal.json + out/pr-body.md + out/<patch>
        │
        ▼  workflow opens
Draft PR  →  human reviews + merges
```

## What ships here

```
workflow.yml              ← copy to .github/workflows/issue-triage.yml
triage_agent/             ← copy to .github/triage_agent/  (or repo root)
   __init__.py
   __main__.py
   main.py                ← the agent itself
   requirements.txt
```

## Installing into your repo

1. **Copy the files** to your repo:

   ```bash
   mkdir -p .github/workflows
   cp -R skills/issue-triage/triage_agent .github/triage_agent
   cp    skills/issue-triage/workflow.yml .github/workflows/issue-triage.yml
   ```

2. **Set up Azure auth** — Workload Identity Federation, see [`../../docs/wif-setup.md`](../../docs/wif-setup.md).

3. **Set the required GitHub secrets** (Settings → Secrets and variables → Actions):

   | Secret | Where to get it |
   |---|---|
   | `AZURE_CLIENT_ID` | The UAMI client ID from `wif-setup.md` |
   | `AZURE_TENANT_ID` | `az account show --query tenantId -o tsv` |
   | `AZURE_SUBSCRIPTION_ID` | `az account show --query id -o tsv` |
   | `AZURE_OPENAI_ENDPOINT` | `az cognitiveservices account show -n <openai> -g <rg> --query properties.endpoint -o tsv` |
   | `APPLICATIONINSIGHTS_CONNECTION_STRING` *(optional)* | Your App Insights connection string for OTel tracing |

4. **Set the repo variables** (Settings → Secrets and variables → Actions → Variables):

   | Variable | Default | Purpose |
   |---|---|---|
   | `TRIAGE_DEPLOYMENT` | `gpt-4o-mini` | Your Azure OpenAI **deployment name** (not the model name) |
   | `ORG_NAME` | repo owner | Display name used in PR body signatures |

5. **Allow Actions to open PRs** — Settings → Actions → General → Workflow permissions → ☑ *Allow GitHub Actions to create and approve pull requests*.

6. **Wire the SRE Agent** to file issues with the `sre-finding` label on this repo (Connectors → GitHub in the portal).

## Testing without the SRE Agent

Use [`../../scripts/simulate-sre-issue.sh`](../../scripts/simulate-sre-issue.sh) to file a synthetic issue with the right label. The workflow fires identically.

## Adapting the agent

The system prompt in `triage_agent/main.py` is intentionally short and conservative. Edit `SYSTEM_PROMPT` to add domain-specific guardrails (e.g., "never propose changes to resources tagged `production`"). The JSON schema can be extended too — just keep the field names stable so the workflow can read them.

## What it does NOT do

- It does not deploy. Only draft PRs are created.
- It does not modify auth/RBAC at scopes wider than the affected resource (enforced in the prompt).
- It does not delete data (enforced in the prompt).
- It does not loop. One issue → one PR. Re-triggering (by re-labeling) updates the existing PR.
