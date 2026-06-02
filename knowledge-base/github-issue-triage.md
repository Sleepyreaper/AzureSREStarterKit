# Runbook: GitHub Issue Triage

> Loaded into SRE Agent memory. Used by the `issue-triager` subagent to classify and route incoming customer-filed issues on `{GITHUB_OWNER}/{GITHUB_REPO}`.

## When to run

The `issue-triager` runs autonomously on issues that:
- Have `[Customer Issue]` in the title, OR
- Have the label `needs-triage`, OR
- Were filed by the SRE Agent's own GitHub connector

Skip issues that already have a comment starting with `🤖 **{YOUR_ORG} SRE Agent**`.

## Classification scheme

For every issue, classify into one of:

| Category | When to use | Default labels |
|---|---|---|
| **Bug** | Reported behavior doesn't match documented behavior | `bug`, plus sub-category |
| **Performance** | Behavior matches docs but is too slow | `performance` |
| **Reliability** | Crashes, hangs, intermittent failures | `reliability` |
| **Security** | Exposure, leak, drift from CIS/NIST control | `security`, `severity:high` |
| **Cost** | Resources wasting money | `cost`, `meter-reader` |
| **Storm/Capacity** | Can't scale to handle load | `storm`, `capacity` |
| **Feature Request** | New capability ask | `enhancement` |
| **Question** | Asks how to use something | `question` |

### Sub-categories for Bug

| Sub-category | Use when |
|---|---|
| `bug:infra` | The broken thing is a Bicep template or Azure config |
| `bug:agent` | The triage agent itself made a mistake |
| `bug:workflow` | A GitHub Actions workflow misbehaved |
| `bug:scenario` | One of the demo scenarios behaves unexpectedly |

## Severity rubric

| Severity | Tag | Use when |
|---|---|---|
| 🔴 P1 / Critical | `severity:critical` | Active exposure, ongoing customer pain, or imminent outage |
| 🟡 P2 / High | `severity:high` | Will cause customer pain within 1 week |
| 🟢 P3 / Medium | `severity:medium` | Should be fixed this sprint but not on fire |
| ⚪ P4 / Low | `severity:low` | Backlog cleanup |

## What to comment

Start every comment with:

```
🤖 **{YOUR_ORG} SRE Agent**
```

Then include:

1. **Classification** — category + sub-category + severity
2. **Brief analysis** — 2-3 sentences on what you understand to be happening
3. **Suggested next step** — one of:
   - "I'll hand this off to `code-analyzer` for deep root cause" (and do it)
   - "Reproduces locally — handing to a human reviewer (P2)"
   - "Need more info: <specific question>"
   - "Duplicate of #<number>, closing"
4. **Status indicator** at end:
   - `✅ Triaged — labels applied`
   - `🔄 Investigating — code-analyzer assigned`
   - `❓ Need more info`
   - `🔒 Closed as duplicate`

## What NOT to do

- ❌ Don't auto-close issues unless they're explicit duplicates
- ❌ Don't apply more than 5 labels (signal-to-noise)
- ❌ Don't attempt remediation in your comment — that's `code-analyzer`'s job
- ❌ Don't ping the reporter unless you actually need info from them
- ❌ Don't add `severity:critical` unless there's evidence of active customer impact

## Examples

### Good triage comment

```
🤖 **{YOUR_ORG} SRE Agent**

**Classification:** Bug → `bug:infra`, severity:medium

**Analysis:** The `ogedemo-storm-vmss` scale set has no autoscale settings (capacity locked at 1). This matches the `storm-no-autoscale` scenario tag. Reproduction is straightforward — `az monitor autoscale list -g {YOUR_RG} --query "[?targetResourceUri contains 'storm-vmss']"` returns empty.

**Suggested next step:** Following `storm-readiness-runbook`. Will propose a CPU-based autoscale Bicep patch.

✅ Triaged — labels applied: `bug:infra`, `severity:medium`, `scenario:storm`
```
