#!/usr/bin/env bash
# =============================================================================
# seed-expiring-cert.sh — plant a "near-expiry" self-signed cert in a Key Vault
#
# Useful for exercising the reliability-fixer subagent without waiting for
# a real cert to age.
#
# Usage:
#   bash scripts/seed-expiring-cert.sh                  # uses $RG and first KV
#   bash scripts/seed-expiring-cert.sh -g <rg>          # explicit RG
#   bash scripts/seed-expiring-cert.sh -g <rg> -v <kv>  # explicit Key Vault
#   bash scripts/seed-expiring-cert.sh -g <rg> -v <kv> -n <cert-name>
# =============================================================================
set -euo pipefail

CERT_NAME="near-expiry-cert"
RG="${RG:-}"
KV_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--resource-group) RG="$2"; shift 2 ;;
    -v|--vault-name)     KV_NAME="$2"; shift 2 ;;
    -n|--cert-name)      CERT_NAME="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$RG" ]]; then
  echo "✗ Resource group required.  -g <rg>   or   export RG=…" >&2
  exit 2
fi

if [[ -z "$KV_NAME" ]]; then
  KV_NAME=$(az keyvault list -g "$RG" --query "[0].name" -o tsv 2>/dev/null || true)
  if [[ -z "$KV_NAME" ]]; then
    echo "✗ No Key Vault found in '$RG'. Create one first, or pass -v <vault-name>." >&2
    exit 1
  fi
  echo "→ Using first Key Vault in $RG: $KV_NAME"
fi

echo "→ Seeding $KV_NAME with near-expiry self-signed cert '$CERT_NAME' ..."

POLICY=$(mktemp -t cert-policy-XXXXXX.json)
trap 'rm -f "$POLICY"' EXIT

cat > "$POLICY" <<JSON
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
JSON

az keyvault certificate create \
  --vault-name "$KV_NAME" \
  --name "$CERT_NAME" \
  --policy @"$POLICY" \
  --query "{name:name, expires:attributes.expires, status:status}" -o table

echo "✓ Done. The cert expires in ~30 days and has no rotation policy attached."
