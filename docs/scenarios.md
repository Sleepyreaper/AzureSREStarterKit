# Demo Scenarios

Four intentionally-broken Azure resources that the Azure SRE Agent should detect, and which the Triage Agent demonstrates fixing.

All four live in `{YOUR_RG}` and are tagged with `scenario=<id>` so the agent can correlate findings to source files.

---

## 1. Storm scenario — VMSS without autoscale

**File:** [`infra/scenarios/01-storm-no-autoscale.bicep`](../infra/scenarios/01-storm-no-autoscale.bicep)

**What's broken:** A VM Scale Set tagged `simulates=customer-portal-tier` is deployed with `capacity: 1` and **no autoscale settings**. During a simulated storm event (load spike), the customer portal tier cannot grow - end users would see degraded experience.

**What SRE Agent should detect:**
- VMSS marked customer-facing has no `Microsoft.Insights/autoscalesettings` attached
- Single-instance scale set on a tier the tags say is customer-facing

**Expected triage agent fix:**
- Bicep snippet adding an `autoscalesettings` resource with CPU-based scale rules (2-10 instances, scale out at 70% CPU)

---

## 2. Security scenario — NSG open to the internet

**File:** [`infra/scenarios/02-security-open-nsg.bicep`](../infra/scenarios/02-security-open-nsg.bicep)

**What's broken:** An NSG with two **deliberately insecure** inbound rules:
- `allow-ssh-from-anywhere` — 22/TCP from `0.0.0.0/0`
- `allow-rdp-from-anywhere` — 3389/TCP from `0.0.0.0/0`

Tagged with `'simulates': 'mgmt-subnet-misconfig'`.

**What SRE Agent should detect:**
- Inbound Allow rules from `*` source on management ports
- Cross-references Microsoft Defender for Cloud "Just-In-Time access" recommendations

**Expected triage agent fix:**
- Tighten `sourceAddressPrefix` to a specific allowlist (corporate egress IPs)
- Or replace with Azure Bastion / JIT access

---

## 3. Cost scenario — orphan disk + idle App Service Plan

**File:** [`infra/scenarios/03-cost-waste.bicep`](../infra/scenarios/03-cost-waste.bicep)

**What's broken:**
- A **1 TB Premium SSD** managed disk with no `managedBy` reference (~$135/month wasted)
- A **P0v3 App Service Plan** with 0 apps hosted (~$60/month wasted)

**What SRE Agent should detect:**
- Disk has been in `Unattached` state for >7 days
- App Service Plan has been at 0 apps for >7 days

**Expected triage agent fix:**
- Delete the orphaned disk (with backup-verification step)
- Either delete the plan, or downsize it to F1 free tier until a workload arrives

---

## 4. Reliability scenario — near-expiry certificate

**File:** [`infra/scenarios/04-reliability-cert.bicep`](../infra/scenarios/04-reliability-cert.bicep)
**Seed script:** [`scripts/seed-expiring-cert.sh`](../scripts/seed-expiring-cert.sh)

**What's broken:** A Key Vault containing a self-signed certificate `near-expiry-cert` with 30-day validity. From day 1 it sits in the "expires in <30 days" alerting window. No auto-rotation policy attached.

**What SRE Agent should detect:**
- Certificate `expires` date is within 30 days
- No `lifetimeActions` configured for auto-rotation

**Expected triage agent fix:**
- Either set a `lifetimeActions` policy that auto-renews at 80% of validity, or rotate immediately with a fresh self-signed cert and update the policy

---

## Tag conventions

Every scenario resource carries these tags:

| Tag | Value | Purpose |
|---|---|---|
| `scenario` | `storm-no-autoscale` / `security-open-ssh` / `cost-orphaned-resources` / `reliability-cert-expiry` | Correlate findings to source files |
| `support-owner` | `demo-team@example.com` | Who to notify (demonstrates a support-owner pattern) |
| `expected-finding` | Short string | What SRE Agent should report |
| `simulates` | What real infrastructure pattern this represents | Demo storytelling |

The triage agent uses these tags as additional context when proposing fixes — it reads `expected-finding` to sanity-check that the issue's reported problem matches the resource's intended demo behavior.

---

## Cleaning up

The whole scenario footprint is idempotent and addressable:

```bash
# Delete just the scenario resources (keeps the RG)
az resource list -g {YOUR_RG} --tag scenario --query "[].id" -o tsv | \
  xargs -n1 az resource delete --ids

# Or nuke and recreate
az group delete -n {YOUR_RG} --yes --no-wait
az group create -n {YOUR_RG} --location eastus2
cd infra/scenarios && bash deploy-all.sh
```

> Note: deleting the resource group also removes the OGEAgenticDemos Foundry account. Don't run that in a real engagement — use the tag-filtered delete instead.
