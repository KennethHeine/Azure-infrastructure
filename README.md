# Azure-infrastructure

Central infrastructure repository that manages Azure resources and GitHub OIDC authentication for other repositories.

## What this repo does

1. **Creates Resource Groups** in an Azure subscription for each onboarded repo
2. **Creates Service Principals** with federated credentials (passwordless OIDC) for each repo
3. **Assigns Owner role** scoped to the repo's own Resource Group (least-privilege)

## Architecture

```
Azure-infrastructure (this repo)
  └── SP: sp-azure-infrastructure-github
        ├── Owner on subscription (creates RGs, assigns roles)
        └── Graph API: Application.ReadWrite.All (creates SPs + federated creds)

Onboarded repos:
  ├── my-app
  │     └── SP: sp-my-app-github → Owner on rg-my-app
  ├── my-api
  │     └── SP: sp-my-api-github → Owner on rg-my-api
  └── ...
```

## Prerequisites

- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) installed
- Logged in with `az login` using an account with **Global Admin** or **Privileged Role Admin** (for initial setup only)

## Initial Setup (one-time)

Run once to create the service principal for this infrastructure repo:

```powershell
.\scripts\setup-service-principal.ps1
```

This creates `sp-azure-infrastructure-github` with:
- **Owner** role on the subscription
- **Microsoft Graph `Application.ReadWrite.All`** (to manage app registrations for other repos)
- Federated credentials for `main` branch and pull requests

After running, add the output secrets to this GitHub repo:
- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

## Onboard a New Repository

### 1. Add the repo name to `repos.json`

```json
{
  "gitHubOrg": "KennethHeine",
  "location": "norwayeast",
  "repos": [
    "my-app",
    "my-api"
  ]
}
```

Each entry is just a repo name string. Names are used to derive:
- Resource Group: `rg-<repo>`
- Service Principal: `sp-<repo>-github`
- Federated credentials: `main` branch + pull requests

### 2. Push to main (or trigger manually)

The **Onboard Repositories** workflow runs automatically when `repos.json` changes on `main`, or you can trigger it manually from the Actions tab.

It processes **every repo in the list** and is **fully idempotent** — existing resources are detected and skipped, so you can run it as many times as you want.

### 3. Add secrets to the onboarded repo

After the workflow runs, check the logs for the output values and add these secrets to each new repo:
- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

### Running locally

```powershell
# Process all repos from repos.json
.\scripts\process-repos.ps1

# Or onboard a single repo directly
.\scripts\create-repo-infrastructure.ps1 -GitHubRepo "my-app"
```

### What gets created per repo

| Resource | Naming | Details |
|---|---|---|
| Resource Group | `rg-<repo>` | In the configured Azure region |
| App Registration | `sp-<repo>-github` | In Azure AD |
| Service Principal | — | Linked to the app registration |
| Federated Credentials | — | OIDC trust for `main` branch + pull requests |
| Role Assignment | — | **Owner** on the repo's Resource Group only |

## Scripts

| Script | Purpose |
|---|---|
| `scripts/setup-service-principal.ps1` | One-time setup of this infra repo's own SP |
| `scripts/create-repo-infrastructure.ps1` | Onboard a single repo (RG + SP + federated creds) |
| `scripts/process-repos.ps1` | Read `repos.json` and onboard all repos in the list |

## Config

| File | Purpose |
|---|---|
| `repos.json` | Array of repos to onboard (with optional per-repo overrides) |
| `repos.schema.json` | JSON schema for `repos.json` (editor validation/autocomplete) |

## GitHub Actions Workflow

| Workflow | Trigger | Purpose |
|---|---|---|
| `onboard-repos.yml` | Push to main (when `repos.json` changes) or manual | Runs `process-repos.ps1` for all repos |
