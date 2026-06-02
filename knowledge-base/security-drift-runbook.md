# Runbook: Security Drift — Open Management Ports

> Loaded into SRE Agent memory. Use when you find an NSG with `Allow` inbound rules from `*` source to management ports (22, 3389, 5985, 5986, 1433, etc.).

## Symptoms

- NSG security rule with `sourceAddressPrefix = "*"` (or `"0.0.0.0/0"` or `"Internet"`)
- Direction `Inbound`, Access `Allow`
- Destination port is a management or sensitive port: 22, 3389, 5985, 5986, 1433, 3306, 5432, 6379, 27017, 9200

## Severity

| Condition | Severity |
|---|---|
| NSG associated with subnet/NIC + public IP attached + Allow rule open to `*` | 🔴 **Critical** — actively exploitable |
| NSG associated but no public exposure (private VNet only) | 🟡 **Warning** — defense in depth violation |
| NSG orphaned (not associated with anything) | 🔵 **Info** — clean up, low urgency |

## Diagnostic steps

1. **Identify the rule(s)**:
   ```bash
   az network nsg rule list -g <rg> --nsg-name <nsg> \
     --query "[?sourceAddressPrefix=='*' && access=='Allow' && direction=='Inbound']" -o table
   ```

2. **Check what's behind the NSG**:
   ```bash
   az network nsg show -g <rg> -n <nsg> \
     --query "{subnets: subnets[].id, nics: networkInterfaces[].id}" -o json
   ```

3. **For each attached subnet/NIC, check public IP exposure**:
   ```bash
   az network nic list -g <rg> --query "[?ipConfigurations[?publicIPAddress != null]].name" -o tsv
   ```

4. **Check Activity Log** for who created/modified the rule:
   ```kusto
   AzureActivity
   | where ResourceProviderValue == 'MICROSOFT.NETWORK'
   | where ResourceGroup == '<RG>'
   | where ActivityStatusValue == 'Success'
   | where OperationNameValue contains 'securityRules/write' or OperationNameValue contains 'networkSecurityGroups/write'
   | project TimeGenerated, Caller, OperationNameValue, _ResourceId
   | order by TimeGenerated desc
   ```

## Remediation patterns

### Pattern A — Restrict to a known CIDR (preferred)

Replace `sourceAddressPrefix: '*'` with the approved management CIDR range, keeping the rule name unchanged for in-place update.

### Pattern B — Replace with Just-In-Time access (best)

For VMs that need occasional management access, enable JIT via Defender for Cloud and then DELETE the open NSG rule.

### Pattern C — Azure Bastion (no public exposure at all)

If the VM is behind an NSG that allows port 22/3389, deploy Azure Bastion in the VNet and remove the inbound rules entirely.

## What to file

Open a GitHub issue using the **incident-report-template** from memory. Required fields: Summary, Impact, Timeline, Evidence, Root Cause, Remediation, Risk, Verification, Action Items, References.

## Anti-patterns

- ❌ Delete the NSG outright — it may have other useful rules
- ❌ Set source to your own personal IP — they change and break things
- ❌ Add a higher-priority Deny without removing the Allow — confusing for next person
- ❌ Skip Activity Log review — knowing who made the change tells you whether this is process or one-off
