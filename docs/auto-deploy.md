# Automated SRE Agent deployment

The repository can deploy and configure the complete starter kit from GitHub
Actions:

- Terraform creates or reconciles the Azure SRE Agent, its user-assigned
  identity, Log Analytics workspace, Application Insights instance, action
  group, and least-privilege role assignments.
- `scripts/apply-sre-config.sh` uploads the checked-in knowledge base, applies
  supported subagents, and connects the Terraform-created telemetry.
- GitHub Actions authenticates to Azure with workload identity federation.
  There is no Azure client secret.

## One-time bootstrap

Run this from an authenticated clone while signed in to the target Azure
subscription and GitHub account:

```bash
az login
gh auth login
bash scripts/bootstrap-auto-deploy.sh
```

The bootstrap creates:

- `rg-sre-agent-demo`, if it does not exist;
- `rg-sre-agent-automation`;
- a user-assigned identity trusted only by the repository's protected
  `production` environment;
- Contributor and Role Based Access Control Administrator assignments limited
  to `rg-sre-agent-demo`;
- GitHub environment variables and a generated Terraform state encryption
  secret.

Override defaults with environment variables:

```bash
GH_REPO=owner/repo \
GH_ENVIRONMENT=production \
WORKLOAD_RG=rg-my-sre-agent \
AGENT_NAME=my-sre-agent \
LOCATION=eastus2 \
MONTHLY_AGENT_UNIT_LIMIT=1000 \
bash scripts/bootstrap-auto-deploy.sh
```

## Deployment behavior

`.github/workflows/sre-agent-auto-deploy.yml` runs when Terraform, knowledge
base, subagent, or configuration files change on `main`. Pull requests run
Terraform format and validation only. The protected `production` environment
controls applies.

The subscription used to build this starter kit enforces private-only Azure
Storage, which prevents GitHub-hosted runners from using an Azure Blob backend.
The workflow therefore encrypts local Terraform state with AES-256, stores only
the encrypted file in GitHub Actions cache, serializes runs with concurrency,
and refreshes the cache twice weekly. When no cache exists, the workflow imports
the deterministic live resources before planning. For production environments,
prefer a private GitHub runner with an Azure Blob backend or Terraform Cloud.

Manual runs support `plan`, `apply`, and guarded `destroy`. Destroy requires the
exact confirmation:

```text
destroy <agent-name>
```

## Optional GitHub Code Access

Automatic repo attachment is disabled until GitHub authentication is provided.
Create a fine-grained PAT with read-only access to the repositories the agent
needs, save it as the `SRE_AGENT_GITHUB_PAT` secret in the `production`
environment, and enable registration:

```bash
gh secret set SRE_AGENT_GITHUB_PAT \
  --env production \
  --repo owner/repo

gh variable set SRE_AGENT_REGISTER_GITHUB_REPO \
  --env production \
  --repo owner/repo \
  --body true
```

The deployment then configures github.com PAT authentication and registers the
current repository through the SRE Agent data plane.

## Operations

Run a plan:

```bash
gh workflow run sre-agent-auto-deploy.yml \
  --repo owner/repo \
  -f action=plan
```

Run an apply:

```bash
gh workflow run sre-agent-auto-deploy.yml \
  --repo owner/repo \
  -f action=apply
```

Verify locally:

```bash
RG=rg-sre-agent-demo \
AGENT_NAME=subscription-sre-agent \
bash scripts/check-sre-agent.sh
```
