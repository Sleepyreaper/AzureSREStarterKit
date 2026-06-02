"""Triage Agent — converts SRE-Agent-filed GitHub issues into proposed fixes.

Architecture:
  1. Issue opened on this repo (filed by Azure SRE Agent or manually).
  2. .github/workflows/issue-triage.yml invokes `python -m agents.triage`
     with the issue body as input.
  3. This script:
       a. Loads the issue + any attached telemetry from the body.
       b. Queries Azure for current state of the named resource(s).
       c. Calls the Foundry agent (o4-mini reasoning model) with
          a strict prompt asking for a structured fix proposal.
       d. Writes a Markdown PR body + Bicep/CLI patch to ./out/.
       e. Workflow then creates a draft PR from those artifacts.

Auth: Azure Workload Identity Federation (GitHub OIDC → Azure AD).
No secrets stored in GitHub — the workflow uses azure/login with
the federated MI configured against this repo.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path

from openai import AzureOpenAI
from azure.identity import DefaultAzureCredential, get_bearer_token_provider


SYSTEM_PROMPT = """You are the Triage Agent for the YourOrg SRE showcase.

You receive a GitHub Issue filed by Azure SRE Agent (or a human) describing
a problem detected in the {YOUR_RG} Azure subscription. Your job:

1. Read the issue title + body. Identify the affected Azure resource(s) and
   the type of finding (security drift, cost waste, reliability gap,
   storm/scale issue, compliance violation).
2. Read the "current state" JSON the workflow has attached — it's the result
   of an Azure Resource Graph query for that resource.
3. Propose a concrete fix as:
   a. A short **executive summary** (2-3 sentences, plain English)
   b. **Root cause** — what's actually wrong
   c. **Proposed fix** — Bicep / CLI / Terraform snippet that resolves it
   d. **Risk** — what could go wrong if applied as-is
   e. **Verification** — how a human reviewer can confirm the fix worked
4. Be conservative. NEVER propose anything that:
   - Deletes data
   - Changes production traffic flow without explicit confirmation
   - Modifies auth/RBAC at scope wider than the affected resource
   When in doubt, propose the smallest reversible change.

Output strictly as JSON matching this schema:

{
  "summary": "string",
  "root_cause": "string",
  "fix": {
    "kind": "bicep" | "cli" | "terraform",
    "filename": "string (relative path inside infra/ or scripts/)",
    "patch": "string (the file content or diff)"
  },
  "risk": "string",
  "verification": "string",
  "human_review_focus": ["string", ...]
}

Reasoning instructions:
- You are running on a reasoning model (o4-mini). Think through the
  classification + remediation carefully internally, but output ONLY
  the JSON object. No prose before or after.
- If the issue doesn't have enough detail to propose a fix, set "fix" to
  null and explain what data you'd need in "summary".
"""


@dataclass
class IssueContext:
    title: str
    body: str
    number: int
    labels: list[str] = field(default_factory=list)
    azure_state: dict | None = None


def _client() -> tuple[AzureOpenAI, str]:
    endpoint = os.environ["AZURE_OPENAI_ENDPOINT"]
    deployment = os.environ.get("TRIAGE_MODEL", "o4-mini")
    cred = DefaultAzureCredential()
    token_provider = get_bearer_token_provider(
        cred, "https://cognitiveservices.azure.com/.default"
    )
    client = AzureOpenAI(
        azure_endpoint=endpoint,
        azure_ad_token_provider=token_provider,
        api_version="2025-01-01-preview",
    )
    return client, deployment


def triage(ctx: IssueContext) -> dict:
    client, deployment = _client()

    user_msg = f"""GITHUB ISSUE
============
Title:  {ctx.title}
Number: #{ctx.number}
Labels: {", ".join(ctx.labels) or "(none)"}

Body:
{ctx.body}

CURRENT AZURE STATE (Resource Graph snapshot)
=============================================
{json.dumps(ctx.azure_state, indent=2, default=str) if ctx.azure_state else "(not attached — proceed with caveats)"}

Produce the JSON triage object now."""

    response = client.chat.completions.create(
        model=deployment,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_msg},
        ],
        response_format={"type": "json_object"},
    )

    raw = response.choices[0].message.content or "{}"
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        return {
            "summary": f"Triage agent produced non-JSON output: {e}",
            "fix": None,
            "raw_output": raw,
        }


def _gather_azure_state(resource_query_hint: str) -> dict | None:
    """Run a best-effort Resource Graph query based on hints in the issue body."""
    if not resource_query_hint:
        return None
    try:
        from azure.identity import DefaultAzureCredential
        from azure.mgmt.resourcegraph import ResourceGraphClient
        from azure.mgmt.resourcegraph.models import QueryRequest

        sub = os.environ.get("AZURE_SUBSCRIPTION_ID")
        if not sub:
            return None
        cred = DefaultAzureCredential()
        client = ResourceGraphClient(cred)
        req = QueryRequest(
            subscriptions=[sub],
            query=resource_query_hint,
        )
        resp = client.resources(req)
        return {"query": resource_query_hint, "rows": resp.data}
    except Exception as exc:  # noqa: BLE001
        return {"query": resource_query_hint, "error": str(exc)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--issue-file", required=True, help="Path to JSON file with issue payload")
    parser.add_argument("--out-dir", default="./out", help="Where to write triage artifacts")
    parser.add_argument("--state-query", default="", help="Optional ARG query to attach")
    args = parser.parse_args(argv)

    issue = json.loads(Path(args.issue_file).read_text())
    ctx = IssueContext(
        title=issue.get("title", ""),
        body=issue.get("body", ""),
        number=int(issue.get("number", 0)),
        labels=[lbl["name"] if isinstance(lbl, dict) else lbl for lbl in issue.get("labels", [])],
        azure_state=_gather_azure_state(args.state_query) if args.state_query else None,
    )

    proposal = triage(ctx)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "proposal.json").write_text(json.dumps(proposal, indent=2))

    md = _render_pr_body(ctx, proposal)
    (out_dir / "pr-body.md").write_text(md)

    fix = proposal.get("fix") or {}
    if fix.get("patch") and fix.get("filename"):
        patch_path = out_dir / Path(fix["filename"]).name
        patch_path.write_text(fix["patch"])

    print(f"✓ Wrote {out_dir / 'proposal.json'} and {out_dir / 'pr-body.md'}")
    return 0


def _render_pr_body(ctx: IssueContext, proposal: dict) -> str:
    fix = proposal.get("fix") or {}
    return f"""## Triage Agent Proposal — closes #{ctx.number}

> Generated by the YourOrg Triage Agent (o4-mini via OGEAgenticDemos Foundry).
> **Human review required before merge.**

### Summary

{proposal.get("summary", "(not provided)")}

### Root cause

{proposal.get("root_cause", "(not provided)")}

### Proposed fix ({fix.get("kind", "n/a")})

```{fix.get("kind", "")}
{fix.get("patch", "(no patch generated)")}
```

Target file: `{fix.get("filename", "(none)")}`

### Risk

{proposal.get("risk", "(not provided)")}

### Verification

{proposal.get("verification", "(not provided)")}

### What the human reviewer should focus on

{chr(10).join("- " + item for item in proposal.get("human_review_focus", []) or ["(not provided)"])}

---

<sub>This PR was generated automatically. The agent did not deploy anything. Approving + merging this PR triggers `.github/workflows/deploy.yml` against `{YOUR_RG}`.</sub>
"""


if __name__ == "__main__":
    sys.exit(main())
