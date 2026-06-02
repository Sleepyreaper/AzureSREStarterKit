# Applying Subagents via the Azure SRE Agent Portal

> **Why this exists:** the data-plane API for creating subagents (`/api/v2/extendedAgent/agents/...`) and the ARM API (`Microsoft.App/agents/{name}/subagents/...`) both currently return `"Agent Extensions are not available for this tenant. This feature is restricted to internal tenants only."` for non-Microsoft-internal tenants. The Azure SRE Agent **portal's Agent Canvas** is not gated — you can create the same subagents manually.
>
> The YAML specs in `subagents/` are the source of truth. This guide tells you how to import them.

## Step-by-step

1. Open https://sre.azure.com → sign in with the same Microsoft account that owns `{YOUR_SRE_AGENT_NAME}`.
2. From the agent list, pick **`{YOUR_SRE_AGENT_NAME}`**.
3. Left navigation → **Builder** → **Agent Canvas**.
4. You'll see the main agent in the centre of the canvas. Click **+ Add custom agent** (or similar — UI changes during preview).
5. For each YAML in `subagents/`, paste the matching fields into the form:

   | YAML key | Portal field | Notes |
   |---|---|---|
   | `spec.name` | **Name** | Lowercase, hyphens, no spaces — e.g., `security-fixer` |
   | `spec.system_prompt` | **System prompt / Instructions** | Paste verbatim. Preserve newlines. |
   | `spec.handoff_description` | **Handoff description** | One-sentence summary the meta-agent sees when deciding to delegate |
   | `spec.agent_type` | **Mode** | Set to **Review** for security-fixer / cost-optimizer / reliability-fixer / code-analyzer. Set to **Autonomous** for issue-triager. |
   | `spec.tools` | **Tools** | Tick each from the YAML list: `SearchMemory`, `RunAzCliReadCommands`, `GetAzCliHelp`, `QueryLogAnalyticsByWorkspaceId`, `QueryAppInsightsByResourceId`, `ExecutePythonCode`. The reasoning-mode subagents in `Review` should NOT have `RunAzCliWriteCommands` ticked. |

6. Click **Save**.

7. (Optional) Wire connectivity:
   - **App telemetry** investigations → the subagents will automatically pick up the `YOUR_APP_INSIGHTS` + `YOUR_LOG_ANALYTICS_WS` connectors we registered on `{YOUR_SRE_AGENT_NAME}`.
   - **Repository access** → `GITHUB_REPO` is already registered as a CodeRepo; subagents can read/grep its files without further config.

## Verifying

Once a subagent is saved:

1. Open the main chat for `{YOUR_SRE_AGENT_NAME}`
2. Type: `/agent security-fixer`
3. Then a prompt, e.g.: `Investigate <your-nsg-name>`
4. The subagent should:
   - SearchMemory for `security-drift-runbook.md`
   - Run `az network nsg show ...` via `RunAzCliReadCommands`
   - Search `GITHUB_REPO` for the Bicep source
   - File a GitHub issue with the incident-report-template format

The plain agent already does this (proven by [Issue #3](https://github.com/{GITHUB_OWNER}/{GITHUB_REPO}/issues/3)) — adding the named subagents just lets you address them directly via `/agent`.

## When the API gate lifts

Once your tenant has the `Agent Extensions` preview feature, you can apply all 5 subagents in one command:

```bash
bash scripts/apply-sre-config.sh --agents-only
```

The script will iterate `subagents/*.yaml` and PUT each one via the management plane. The portal-created subagents and API-created subagents are identical — you can mix and match.

## Source-of-truth ordering

If the YAML in `subagents/` ever drifts from what's deployed in the portal:

1. **Prefer the YAML** — that's what gets reviewed via PRs and what gets re-applied via `apply-sre-config.sh`.
2. After any portal edit, **export back to YAML** by inspecting the agent canvas and updating the matching file in this repo.
3. Open a PR with the diff so the change is auditable.
