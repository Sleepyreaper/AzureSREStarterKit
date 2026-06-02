#!/usr/bin/env bash
# Seeds the Key Vault from scenario 04 with a near-expiry self-signed cert.
# Run after `bash infra/scenarios/deploy-all.sh`.
set -euo pipefail

RG="${1:-{YOUR_RG}}"
KV_NAME="$(az keyvault list -g "$RG" --query "[?starts_with(name, 'ogekv')] | [0].name" -o tsv)"

if [ -z "$KV_NAME" ]; then
  echo "✗ Could not find reliability scenario Key Vault. Run scenario 4 deploy first."
  exit 1
fi

echo "→ Seeding $KV_NAME with near-expiry self-signed cert 'near-expiry-cert'..."

# Build a policy with 30-day validity, so the cert is "near-expiry" from day 1.
cat > /tmp/cert-policy.json <<'EOF'
{
  "issuerParameters": { "name": "Self" },
  "x509CertificateProperties": {
    "subject": "CN=sre-demo-near-expiry",
    "validityInMonths": 1,
    "keyUsage": ["digitalSignature", "keyEncipherment"]
  },
  "keyProperties": {
    "exportable": true,
    "keyType": "RSA",
    "keySize": 2048,
    "reuseKey": false
  },
  "secretProperties": { "contentType": "application/x-pkcs12" },
  "lifetimeActions": []
}
EOF

az keyvault certificate create \
  --vault-name "$KV_NAME" \
  --name "near-expiry-cert" \
  --policy @/tmp/cert-policy.json \
  --query "{name:name, expires:attributes.expires, status:status}" -o table

echo "✓ Done. The cert expires in ~30 days and has no rotation policy attached."
