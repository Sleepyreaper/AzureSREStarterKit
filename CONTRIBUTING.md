# Contributing to the Azure SRE Agent Starter Kit

Thanks for considering a contribution! This kit thrives on real-world subagents and runbooks. A few conventions to keep things consistent.

## What we love PRs for

- **New subagent specs** for scenarios not yet covered (databases, network egress, identity drift, FinOps tagging, etc.)
- **New runbooks** in `knowledge-base/` paired with a subagent that uses them
- **Bicep stubs in `infra/scenarios/`** for the four scenarios in `docs/scenarios.md`
- **Bug fixes** in scripts, the triage skill, or docs

## Repo conventions

### Subagents (`subagents/*.yaml`)

- One file per subagent. Filename = `spec.name`.
- All YAML keys at the spec level are required: `name`, `system_prompt`, `handoff_description`, `agent_type`, `tools`.
- `agent_type` is `Review` by default. Only use `Autonomous` for low-risk read-only or comment-only flows.
- `tools` list must NOT include `RunAzCliWriteCommands` on `Review` agents — defence in depth, even if the mode would prevent the write.
- System prompts must reference any runbook they rely on by exact filename (without extension), so `SearchMemory` can find it.
- Use `{LIKE_THIS}` for placeholders — see the table in `README.md`. Don't bake real resource group / account names into prompts.

### Runbooks (`knowledge-base/*.md`)

- Filename is lowercase-kebab, ends in `-runbook.md` for procedural docs (`incident-report-template.md` and `example-environment-architecture.md` are the two exceptions).
- Start with a short purpose statement so the LLM ranks it correctly when searched.
- Reference subagents by exact name (e.g. `` `security-fixer` ``).
- Don't reference resources that don't exist in the kit (no `agents/triage/`, no `sre-config/agents/`).

### Scripts (`scripts/*.sh`)

- Always `set -uo pipefail` (NOT `-e` — we handle errors explicitly so we can fail loudly with messages).
- Validate required env vars at the top; refuse to run with placeholder-looking values (`*YOUR_*`, `*{*}*`).
- Use `mktemp` for any temp files; never write to `/tmp/<fixed-name>`.
- Use `--query`/`-o tsv`/`--only-show-errors` on `az` calls so output is parseable.
- Run `bash -n scripts/your-script.sh` before pushing.

### Python (`skills/issue-triage/triage_agent/`)

- Python 3.13 (matches the `actions/setup-python` version in `workflow.yml`).
- No new top-level dependencies without justification — every dep is one more thing for users to install.
- Run `python3 -c "import ast; ast.parse(open('main.py').read())"` before pushing.

### Docs (`docs/*.md`)

- Cross-link with markdown links (e.g. `[`apply-sre-config.sh`](../scripts/apply-sre-config.sh)`). Don't reference files by name alone.
- Every code block that's meant to be run must be self-contained (set its own env vars at the top).
- No internal codenames, customer names, or organisation names. The kit is for everyone.

## Before opening a PR

1. `grep -rn "YourCustomer\|YourOrg" .` returns nothing
2. All `.sh` files pass `bash -n`
3. All `.py` files parse cleanly
4. All YAML loads cleanly: `python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]" subagents/*.yaml`
5. All markdown links resolve to real files

## Issues and discussions

Open an issue for design questions before writing a big PR — happy to give early feedback on subagent prompts so you don't waste time.
