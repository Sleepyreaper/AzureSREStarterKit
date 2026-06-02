# Triage Agent Design

## What it is

A single LLM-backed Python agent that reads a GitHub issue filed by Azure SRE Agent (or a human) and produces a **structured fix proposal** as a Markdown PR body + Bicep/CLI patch.

**Where it lives:** [`skills/issue-triage/triage_agent/main.py`](../skills/issue-triage/triage_agent/main.py)
**Where it runs:** GitHub Actions runner (Ubuntu Python 3.13), authenticated to Azure via Workload Identity Federation.
**Where it calls:** the Azure OpenAI deployment named by `TRIAGE_DEPLOYMENT` (defaults to `gpt-4o-mini`).

## Why a single agent, not a council?

A council of specialists makes sense when the value of the demo is *interactive* operational reasoning — humans benefit from watching cost vs reliability argue out loud.

This triage agent has a *narrower, structured job*: take an incident, produce a fix proposal. Structure beats debate here, so:

- **One model call** with a strict JSON output schema
- **Deterministic** — the GitHub workflow can parse the response without LLM-style ambiguity
- **No conversational state** — every issue is a fresh call

If a future use case wants debate (e.g., cost vs security arguing about an autoscale fix), wire a multi-agent council in by calling its endpoint from the workflow instead of replacing this triage agent.

## Architecture

```
GitHub Issue (#42)
       │  labeled `sre-finding`
       ▼
.github/workflows/issue-triage.yml          (skills/issue-triage/workflow.yml)
       │  gh-actions: checkout, setup-python, azure/login WIF
       ▼
python -m triage_agent \
   --issue-file out/issue.json \
   --state-query "Resources | where ..."
       │
       ▼
triage_agent/main.py
   ├── Loads issue JSON
   ├── (Optional) Runs ARG query to attach current Azure state
   ├── Calls AzureOpenAI.chat.completions.create(
   │       model = TRIAGE_DEPLOYMENT,
   │       response_format = json_object,
   │       messages = [SYSTEM_PROMPT, user(issue + state)])
   ├── Parses JSON
   └── Writes out/proposal.json + out/pr-body.md + out/<patch-file>
       │
       ▼
gh pr create --draft --label "agent-proposal,needs-human-review"
       │
       ▼
PR body has summary, root cause, proposed fix (Bicep), risk, verification
```

## The system prompt

See `SYSTEM_PROMPT` in [`skills/issue-triage/triage_agent/main.py`](../skills/issue-triage/triage_agent/main.py).

Key rules baked in:
1. **Strict JSON output schema** — the prompt enumerates required keys
2. **Safety constraints** — never delete data, never broaden auth scope
3. **Smallest reversible change** — bias toward conservative fixes
4. **Reasoning-output guidance** — reason internally, emit JSON only (reasoning models otherwise leak chain-of-thought)
5. **Honest unknowns** — if data is insufficient, set `fix: null` and explain what's needed

## Auth

Uses `azure.identity.DefaultAzureCredential`:
- **In CI**: the `azure/login@v2` action sets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE` env vars — `DefaultAzureCredential` picks up the OIDC flow.
- **Locally**: `az login` works — same code path, no config changes.

The federated MI needs:
- `Cognitive Services OpenAI User` on the Azure OpenAI resource that hosts `TRIAGE_DEPLOYMENT`
- `Reader` on the subscription (to run ARG queries for `--state-query`)

Full setup instructions: [`docs/wif-setup.md`](wif-setup.md).

## Telemetry / evaluation

If `APPLICATIONINSIGHTS_CONNECTION_STRING` is set, the agent initialises `azure-monitor-opentelemetry` at import time (see the guarded `configure_azure_monitor()` call in `main.py`). Every `chat.completions.create` call is captured with prompt + completion length, latency, and any exceptions.

For continuous evaluation, the recommended pattern is to:
1. Maintain a small dataset of `(issue, expected_fix)` pairs in your IaC repo
2. Use Azure AI Foundry's evaluation framework (or your preferred eval harness) to score agent outputs against the dataset for: groundedness, relevance, similarity to expected fix
3. Wire eval runs into a nightly GitHub Action

## Extending

### Add a new scenario type

1. Drop the Bicep for the new broken-on-purpose resource into your IaC repo
2. Add a case to [`scripts/simulate-sre-issue.sh`](../scripts/simulate-sre-issue.sh) for synthetic testing
3. Update [`docs/scenarios.md`](scenarios.md) and add a matching runbook in `knowledge-base/` if the existing ones don't cover it

The triage agent doesn't need any code changes — it reasons over the issue body + ARG state, and the new scenario just produces new findings.

### Swap to a different model

Change the `TRIAGE_DEPLOYMENT` GitHub Actions variable (or repo secret) in `.github/workflows/issue-triage.yml`. The value must be the **deployment name** in your Azure OpenAI resource, not a model name. Recommended deployments:

- `gpt-4o-mini` (default) — cheap, fast, fine for triage
- `gpt-4o` — synthesis-heavy, strict JSON format adherence
- An `o`-series reasoning deployment — slower, better RCA

### Add domain knowledge

Mount additional files into the system prompt context. E.g., to teach the agent your Terraform conventions, append the contents of `docs/terraform-style.md` to the user message before the issue body.

For a more sophisticated path, migrate to **Foundry Agent Service** with tool calling — the agent could query Resource Graph itself instead of having the workflow pre-attach state. That trades determinism for autonomy; today we prefer determinism.

## What it does NOT do

- **Does not deploy.** Only PRs are created. Deployment is gated by human merge + your own separate deploy workflow.
- **Does not modify auth/RBAC** at scopes wider than the affected resource.
- **Does not delete data.** Disk `delete` operations on disks containing data are explicitly forbidden in the system prompt; if needed, the agent proposes a snapshot-then-delete pattern.
- **Does not loop.** One issue → one PR. Re-triggering (by re-labeling) updates the existing PR.
