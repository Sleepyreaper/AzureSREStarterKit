# Triage Agent Design

## What it is

A single Foundry-hosted agent that reads GitHub issues filed by Azure SRE Agent (or humans) and produces a **structured fix proposal** as a Markdown PR body + Bicep/CLI patch.

**Where it lives:** [`agents/triage/main.py`](../agents/triage/main.py)
**Where it runs:** GitHub Actions runner (Ubuntu Python 3.13), authenticated to Azure via Workload Identity Federation.
**Where it calls:** Azure AI Foundry `{PROTECTED_RESOURCE}` deployment `o4-mini` (reasoning model).

## Why a single agent, not a council?

The sister Cloud Weather Operations platform uses a 6-agent debate council because that's the value of *interactive* operational reasoning — humans benefit from watching cost vs reliability argue.

This triage agent has a *narrower, structured job*: take an incident, produce a fix proposal. Structure beats debate here, so:

- **One reasoning model** (`o4-mini`) — chains through classification + remediation
- **One strict JSON output schema** — workflow can parse without LLM-style ambiguity
- **No conversational state** — every issue is a fresh call

If a future demo wants debate (e.g., cost reviewer vs security reviewer arguing about an autoscale fix), wire a multi-agent council in by calling its `/api/ask` endpoint from the workflow instead.

## Architecture

```
GitHub Issue (#42)
       │
       ▼
.github/workflows/issue-triage.yml
       │  (gh actions: checkout, setup-python, azure/login WIF)
       ▼
python -m agents.triage \
   --issue-file out/issue.json \
   --state-query "Resources | where ... "
       │
       ▼
agents/triage/main.py
   ├── Loads issue JSON
   ├── (Optional) Runs ARG query to attach current Azure state
   ├── Calls AzureOpenAI.chat.completions.create(...)
   │       model = o4-mini
   │       response_format = json_object
   │       messages =
   │           system: SYSTEM_PROMPT (anti-hallucination, JSON schema)
   │           user: issue title + body + Azure state
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

See [`agents/triage/main.py`](../agents/triage/main.py) — the `SYSTEM_PROMPT` constant.

Key rules baked in:
1. **Strict JSON output schema** — the prompt enumerates required keys
2. **Safety constraints** — never delete data, never broaden auth scope
3. **Smallest reversible change** — bias toward conservative fixes
4. **Reasoning-output guidance** — reason internally, emit JSON only (reasoning models otherwise leak chain-of-thought)
5. **Honest unknowns** — if data is insufficient, set `fix: null` and explain what's needed

## Auth

Uses `azure.identity.DefaultAzureCredential`:
- In CI: the `azure/login@v2` action sets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE` env vars — `DefaultAzureCredential` picks up the OIDC flow.
- Locally: `az login` works too — same code path, no config changes.

The federated MI needs:
- `Cognitive Services OpenAI User` on `{PROTECTED_RESOURCE}`
- `Reader` on the subscription (to run ARG queries for `--state-query`)
- `Contributor` on `{YOUR_RG}` (only required for `deploy.yml`, not this agent)

## Telemetry / evaluation

If `APPLICATIONINSIGHTS_CONNECTION_STRING` is set, the agent inherits OpenTelemetry tracing via the same `azure-monitor-opentelemetry` distro the sister app uses. Every `chat.completions.create` is captured with prompt + completion length, latency, and any exceptions.

For continuous evaluation, the recommended pattern is to:
1. Maintain a dataset of "ground truth" (issue → expected fix) in `agents/triage/eval/`
2. Use Azure AI Foundry's evaluation framework to score new agent outputs against the dataset for: groundedness, relevance, similarity to expected fix
3. Wire eval runs into a nightly GitHub Action (`.github/workflows/eval-nightly.yml` — not yet created)

## Extending

### Add a new scenario type

1. Drop a Bicep file in `infra/scenarios/<NN>-<name>.bicep`
2. Add a case to `scripts/simulate-sre-issue.sh` for synthetic testing
3. Update `docs/scenarios.md`

The triage agent doesn't need any code changes — it reasons over the issue body + ARG state, and the new scenario just produces new findings.

### Swap to a different model

Set the `TRIAGE_MODEL` env var in `.github/workflows/issue-triage.yml`. Options:
- `o4-mini` (default) — reasoning model, slower, better RCA
- `gpt-5.4` — synthesis, faster, stricter JSON format adherence
- `gpt-5.4-mini` — cheapest, good for high-volume triage

### Add domain knowledge

Mount additional files into the system prompt context. E.g., to teach the agent your Terraform conventions, append the contents of `docs/terraform-style.md` to the user message before the issue body.

For a more sophisticated path, migrate to **Foundry Agent Service** with tool calling — the agent could query Resource Graph itself instead of having the workflow pre-attach state. That trades determinism for autonomy; today we prefer determinism.

## What it does NOT do

- It does not deploy. Only PRs are created. Deployment is gated by human merge + a separate workflow.
- It does not modify auth/RBAC at scopes wider than the affected resource.
- It does not delete data. `Microsoft.Compute/disks` `delete` operations on disks containing data are explicitly forbidden in the system prompt; if needed, the agent proposes a snapshot-then-delete pattern.
- It does not loop. One issue → one PR. Re-triggering (by re-labeling) replaces the previous PR.
