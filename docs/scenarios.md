# Demo Scenarios

The starter kit ships with **runbooks and subagent prompts**, but not the Bicep that creates the "broken-on-purpose" Azure resources to investigate. That part is intentional — every team's environment is different, and shipping fake infrastructure tends to drift and confuse newcomers.

This doc instead describes **four scenarios that pair well with the runbooks in `knowledge-base/`**, with enough detail that you can stand up your own version in 15 minutes per scenario. Each one is designed to give the matching subagent a satisfying investigation loop end-to-end.

> If you want to contribute a turn-key Bicep implementation for any of these, PRs welcome — drop it in `infra/scenarios/` and link to it from this doc.

All four scenarios should live in `{YOUR_RG}` and be tagged with `scenario=<id>` so the agent can correlate findings.

---

## 1. Storm scenario — VMSS without autoscale

**What's broken:** A VM Scale Set tagged `simulates=customer-portal-tier` is deployed with `capacity: 1` and **no autoscale settings**. During a simulated storm event (load spike), the customer portal tier cannot grow — end users would see degraded experience.

**Matching runbook:** `knowledge-base/storm-readiness-runbook.md`

**What SRE Agent should detect:**
- VMSS marked customer-facing has no `Microsoft.Insights/autoscalesettings` attached
- Single-instance scale set on a tier whose tags mark it customer-facing

**Expected `reliability-fixer` proposal:**
- Bicep snippet adding an `autoscalesettings` resource with CPU-based scale rules (2-10 instances, scale out at 70 % CPU)

**Minimum Bicep to seed it:** one `Microsoft.Compute/virtualMachineScaleSets` with `sku.capacity: 1`, `tags: { scenario: 'storm-no-autoscale', simulates: 'customer-portal-tier' }`.

---

## 2. Security scenario — NSG open to the internet

**What's broken:** An NSG with two **deliberately insecure** inbound rules:
- `allow-ssh-from-anywhere` — 22/TCP from `0.0.0.0/0`
- `allow-rdp-from-anywhere` — 3389/TCP from `0.0.0.0/0`

Tagged with `simulates=mgmt-subnet-misconfig`.

**Matching runbook:** `knowledge-base/security-drift-runbook.md`

**What SRE Agent should detect:**
- Inbound `Allow` rules from `*` source on management ports
- Cross-references Microsoft Defender for Cloud "Just-In-Time access" recommendations

**Expected `security-fixer` proposal:**
- Tighten `sourceAddressPrefix` to a specific allowlist (corporate egress IPs)
- Or replace with Azure Bastion / JIT access

**Minimum Bicep to seed it:** one `Microsoft.Network/networkSecurityGroups` with the two rules above; optionally attach to a subnet so it isn't flagged "orphaned".

---

## 3. Cost scenario — orphan disk + idle App Service Plan

**What's broken:**
- A **1 TB Premium SSD** managed disk with no `managedBy` reference (~$135/month wasted)
- A **P0v3 App Service Plan** with 0 apps hosted (~$60/month wasted)

**Matching runbook:** `knowledge-base/cost-waste-runbook.md`

**What SRE Agent should detect:**
- Disk has been in `Unattached` state for >7 days
- App Service Plan has been at 0 apps for >7 days

**Expected `cost-optimizer` proposal:**
- Snapshot + delete the orphaned disk
- Either delete the plan, or downsize it to F1 free tier until a workload arrives

**Minimum Bicep to seed it:** one `Microsoft.Compute/disks` with `creationData.createOption: 'Empty'` and no `managedBy`, plus one `Microsoft.Web/serverfarms` with no `Microsoft.Web/sites` attached.

---

## 4. Reliability scenario — near-expiry certificate

**What's broken:** A Key Vault containing a self-signed certificate (`near-expiry-cert`) with 30-day validity. From day 1 it sits in the "expires in <30 days" alerting window. No auto-rotation policy attached.

**Matching runbook:** `knowledge-base/reliability-runbook.md`

**Seed script (ships with this repo):** [`scripts/seed-expiring-cert.sh`](../scripts/seed-expiring-cert.sh) — point it at any Key Vault in `{YOUR_RG}` and it plants the cert.

**What SRE Agent should detect:**
- Certificate `expires` date is within 30 days
- No `lifetimeActions` configured for auto-rotation

**Expected `reliability-fixer` proposal:**
- Either set a `lifetimeActions` policy that auto-renews at 80 % of validity, or rotate immediately with a fresh self-signed cert and update the policy

---

## Tag conventions for all four

Every scenario resource should carry these tags so the agent can correlate findings back to source files and intent:

| Tag | Value | Purpose |
|---|---|---|
| `scenario` | `storm-no-autoscale` / `security-open-ssh` / `cost-orphaned-resources` / `reliability-cert-expiry` | Correlate findings to source files |
| `owner` | `demo-team@example.com` | Who to notify (demonstrates a support-owner pattern) |
| `expected-finding` | Short string describing what should be found | Lets the agent sanity-check its diagnosis |
| `simulates` | What real infrastructure pattern this represents | Demo storytelling |

The subagents look up `expected-finding` to verify the issue they're reporting matches the resource's intended demo behavior.

---

## Cleaning up

If you tag everything with `scenario=<id>`, cleanup is one command:

```bash
az resource list -g {YOUR_RG} --tag scenario --query "[].id" -o tsv | \
  xargs -n1 az resource delete --ids
```

> Don't `az group delete` unless `{YOUR_RG}` is genuinely a sandbox. Some users co-locate the SRE Agent and its UAMI in the same RG; deleting the RG removes them too.
