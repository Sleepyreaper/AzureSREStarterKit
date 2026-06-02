# Runbook: Reliability — Cert / Key / Secret Expiry

> Loaded into SRE Agent memory. Use when a Key Vault certificate, key, or secret is approaching expiry, or when an app reports auth/TLS failures.

## Symptoms

| Finding | Detection |
|---|---|
| Certificate near expiry | `expires - now() < 30 days` |
| No rotation policy | `lifetimeActions` is null on the cert version |
| Recent auth failures correlated with cert age | App Insights `requests` with `4xx`/`5xx` spike and cert age >360 days |
| Manual rotation overdue | KV audit logs show no recent `CertificatePolicyUpdate` |

## Severity

| Days until expiry | Severity |
|---|---|
| < 7 days | 🔴 **Critical** — outage imminent |
| 7-30 days | 🟡 **Warning** — schedule rotation this sprint |
| > 30 days but no rotation policy | 🔵 **Info** — fix the policy, not the cert |

## Diagnostic steps

1. **List certs with expiry**:
   ```bash
   az keyvault certificate list --vault-name <kv> \
     --query "[].{name:name, expires:attributes.expires, enabled:attributes.enabled}" -o table
   ```

2. **Get the cert's full policy** (especially `lifetimeActions`):
   ```bash
   az keyvault certificate show --vault-name <kv> --name <cert-name>
   ```

3. **Find who/what is using the cert** (App Insights dependencies):
   ```kusto
   dependencies
   | where target contains "<kv-name>.vault.azure.net"
   | where data contains "<cert-name>"
   | summarize requests=count(), apps=make_set(cloud_RoleName) by bin(timestamp, 1d)
   ```

4. **Check Activity Log for recent rotation attempts**:
   ```kusto
   AzureActivity
   | where _ResourceId contains "<kv-name>"
   | where OperationNameValue contains "Certificate"
   ```

## Remediation patterns

### Pattern A — Set auto-rotation policy (best — fixes root cause)

Most certificate problems are policy problems. Add a `lifetimeActions` block to the cert policy with `AutoRenew` trigger 30 days before expiry.

### Pattern B — Rotate immediately

For already-expired or near-expiry. `az keyvault certificate create` creates a new version; consumers using "latest" pick it up automatically. Consumers that pin a version need manual notification.

### Pattern C — Replace self-signed with CA-issued

If the cert was self-signed for testing but is now in a near-production path, replace with an Azure Key Vault issuer (DigiCert, GlobalSign, or Internal CA).

## What to file

Use the incident-report-template. Required: Summary (cert + KV + days remaining), Impact (which apps depend on it from App Insights), Timeline (created, expires, last rotation), Evidence (policy JSON + dependency count), Root Cause (`policy-bug` / `forgotten-rotation` / `consumer-pinning`), Remediation (Pattern A/B/C), Risk (consumer breakage on thumbprint change), Verification.

## Anti-patterns

- ❌ Just extending validity manually — band-aid; recurs next year
- ❌ Auto-renewing without notifying consumers — thumbprint pinners break
- ❌ Moving to a different Key Vault "to be safe" — operational complexity for no security gain
