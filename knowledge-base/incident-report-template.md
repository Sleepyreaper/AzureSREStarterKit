# Incident Report Template

> Use this exact structure when filing GitHub issues. The triage workflow and downstream automation depend on the section headers.

```markdown
## Summary
One-sentence executive summary of what's wrong and what's at stake.

## Impact
- **Affected resources**: <bullet list with full ARM resource IDs>
- **Customer-facing impact**: <who is affected, how, and how badly>
- **Estimated dollar / risk impact**: <cite source — Advisor, Cost Mgmt, or labeled "estimate">

## Timeline
- `YYYY-MM-DD HH:MM UTC` — <event>
- `YYYY-MM-DD HH:MM UTC` — <event>

## Evidence
### Telemetry
<KQL query results, CLI command output, screenshots if applicable>

### Source code references
<file:line references from GitHub source code search, if a code-analyzer ran>

## Root Cause
Classify the root cause as ONE of:
- **policy-bug** — the defining policy/IaC is wrong; fix the definition
- **misconfiguration** — the resource is wrong; fix the resource
- **drift** — IaC and live state diverged; reconcile
- **intentional-exemption** — known/documented; verify exemption is current
- **workaround-abuse** — someone bypassed the control; redesign the control

Then explain what specifically went wrong, in 2-4 sentences.

## Remediation

### Proposed fix
<Bicep / Terraform / CLI snippet that resolves the issue>

### Risk
What could go wrong if this fix is applied as-is? Be specific:
- Could it cause downtime?
- Could it lock someone out?
- Are there dependencies that break?

### Verification
How does the reviewer confirm the fix worked after deployment?

## Action Items
- [ ] Owner: <support-owner email from resource tags>
- [ ] Priority: P1 / P2 / P3 / P4
- [ ] Sprint: <next/this/future>
- [ ] Related PR: <fill in once opened>
- [ ] Related runbook update: <only if this incident exposed a runbook gap>

## References
- ARM Resource IDs:
  - `<full resource ID 1>`
- Log Analytics Workspace ID: `<workspace customer ID>`
- App Insights Resource ID: `<full ARM ID>`
- Activity Log entry IDs: `<correlation IDs>`
- Defender for Cloud assessment IDs (if applicable): `<assessment IDs>`
- Advisor recommendation IDs (if applicable): `<recommendation IDs>`
- Related issues: `#<number>`
```

## Rules for filling this in

1. **Never invent specifics.** If you don't have an exact value, write `(not available)` rather than guessing a number, name, or ID.
2. **Always include References.** Empty references = unverifiable claim = wasted reviewer time.
3. **One incident per issue.** If you find 4 problems, file 4 issues. Don't bundle.
4. **Quote your sources.** If you reference Advisor, quote the recommendation. If you reference a KQL result, paste the query AND the row count.
5. **Label appropriately.** Add labels: `sre-finding`, `needs-triage`, plus one of `scenario:security`, `scenario:cost`, `scenario:reliability`, `scenario:storm`.
6. **Match the runbook.** Cite which runbook you followed (`security-drift-runbook`, etc.) so the reviewer can audit your reasoning.
