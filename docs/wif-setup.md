# Workload Identity Federation Setup

The triage workflow authenticates to Azure using GitHub Actions OIDC tokens — no client secret stored in GitHub. This is the recommended pattern for Azure-from-Actions and is required by the triage skill.

This guide walks you through:

1. Create a User-Assigned Managed Identity (UAMI)
2. Add federated identity credentials trusting your GitHub repo
3. Grant the UAMI the Azure roles the triage agent needs
4. Set the GitHub Actions secrets

Total time: ~5 minutes once `az` is logged in.

---

## Prerequisites

- Owner-level access on the Azure subscription (to create UAMI and role assignments)
- Admin on the GitHub repo (to set secrets)
- `az` CLI logged in: `az login && az account set --subscription <id>`

## Variables you'll reuse

```bash
SUB=$(az account show --query id -o tsv)
TENANT=$(az account show --query tenantId -o tsv)
RG=rg-triage-identity        # or any RG; can co-locate with your SRE Agent
LOCATION=eastus2
UAMI_NAME=triage-agent-mi
GH_OWNER=your-github-org-or-user
GH_REPO=your-repo
OPENAI_RG=rg-your-openai
OPENAI_NAME=your-openai
```

## 1. Create the UAMI

```bash
az group create -n "$RG" -l "$LOCATION" --only-show-errors
az identity create -g "$RG" -n "$UAMI_NAME" --only-show-errors

CLIENT_ID=$(az identity show -g "$RG" -n "$UAMI_NAME" --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show -g "$RG" -n "$UAMI_NAME" --query principalId -o tsv)
echo "CLIENT_ID=$CLIENT_ID"
echo "PRINCIPAL_ID=$PRINCIPAL_ID"
```

## 2. Trust GitHub Actions OIDC

The triage workflow is triggered by `on: issues` (and `workflow_dispatch`). Both run on the repo's default branch ref, so the OIDC subject you need is:

```bash
# Substitute your actual default branch (commonly `main`, but `master`,
# `trunk`, etc. all work — match exactly what `gh repo view --json
# defaultBranchRef --jq .defaultBranchRef.name` reports).
DEFAULT_BRANCH=$(gh repo view "${GH_OWNER}/${GH_REPO}" --json defaultBranchRef --jq '.defaultBranchRef.name')

az identity federated-credential create \
  -g "$RG" --identity-name "$UAMI_NAME" \
  --name gh-default-branch \
  --issuer "https://token.actions.githubusercontent.com" \
  --audiences "api://AzureADTokenExchange" \
  --subject "repo:${GH_OWNER}/${GH_REPO}:ref:refs/heads/${DEFAULT_BRANCH}"
```

If you later extend the workflow to trigger on pull requests, environments, or tags, add additional credentials for those subjects:

| Trigger added | Subject to add |
|---|---|
| `on: pull_request` | `repo:OWNER/REPO:pull_request` |
| `environment: production` | `repo:OWNER/REPO:environment:production` |
| Tag pushes | `repo:OWNER/REPO:ref:refs/tags/<tag-pattern>` |

> See https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect for the full subject grammar.

## 3. Grant the UAMI the roles it needs

```bash
# Read-only on the subscription (needed for Azure Resource Graph queries
# performed by the agent's --state-query option).
az role assignment create \
  --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Reader" \
  --scope "/subscriptions/${SUB}"

# Permission to call your Azure OpenAI deployment.
az role assignment create \
  --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services OpenAI User" \
  --scope "/subscriptions/${SUB}/resourceGroups/${OPENAI_RG}/providers/Microsoft.CognitiveServices/accounts/${OPENAI_NAME}"
```

> If you want the agent to be able to *propose* changes informed by Activity Log or Monitor data, also grant `Monitoring Reader` and `Log Analytics Reader` on the appropriate scopes. The agent never writes to Azure — those reads just give it richer evidence.

## 4. Set GitHub secrets

```bash
gh secret set AZURE_CLIENT_ID       --body "$CLIENT_ID"      --repo "${GH_OWNER}/${GH_REPO}"
gh secret set AZURE_TENANT_ID       --body "$TENANT"         --repo "${GH_OWNER}/${GH_REPO}"
gh secret set AZURE_SUBSCRIPTION_ID --body "$SUB"            --repo "${GH_OWNER}/${GH_REPO}"
gh secret set AZURE_OPENAI_ENDPOINT --body "$(az cognitiveservices account show -n "$OPENAI_NAME" -g "$OPENAI_RG" --query properties.endpoint -o tsv)" --repo "${GH_OWNER}/${GH_REPO}"

# Optional — OTel tracing
# gh secret set APPLICATIONINSIGHTS_CONNECTION_STRING --body "<your-connection-string>" --repo "${GH_OWNER}/${GH_REPO}"
```

And the repo variables (visible in workflow logs, intentional):

```bash
gh variable set TRIAGE_DEPLOYMENT --body "gpt-4o-mini" --repo "${GH_OWNER}/${GH_REPO}"
gh variable set ORG_NAME          --body "Acme"        --repo "${GH_OWNER}/${GH_REPO}"
```

## 5. Smoke test

From a clone of your repo (the simulate script files a real issue with the right label, which fires the workflow):

```bash
bash scripts/simulate-sre-issue.sh "Test SRE finding" security web-nsg "$RG"
```

Or, if you've kept the `workflow_dispatch` trigger:

```bash
gh workflow run issue-triage.yml --repo "${GH_OWNER}/${GH_REPO}" -f issue_number=<existing-issue-number>
```

Watch the run with `gh run watch`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `AADSTS70021: No matching federated identity record found` | OIDC `sub` claim from the run doesn't match any credential | Check the run logs for `Subject: …` and add a matching `--subject` |
| `403 — does not have authorization to perform action 'Microsoft.CognitiveServices/accounts/listKeys'` | UAMI missing OpenAI role | Re-run the role assignment for `Cognitive Services OpenAI User` |
| `DeploymentNotFound` | `TRIAGE_DEPLOYMENT` set to a model name (e.g. `gpt-4o`) instead of your deployment name | Set the variable to the exact deployment name in your Azure OpenAI resource |
| `GitHub Actions is not permitted to create or approve pull requests` | Repo setting blocks PR creation | Settings → Actions → General → Workflow permissions → tick "Allow GitHub Actions to create and approve pull requests" |
