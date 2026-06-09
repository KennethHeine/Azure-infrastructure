# Azure-infrastructure

Control-plane repository for Kenneth's Azure + GitHub estate. It onboards new
application repositories, provisions their **isolated** Azure footprint, and
provides one-click workflows to add or decommission repos. Everything is
**OIDC / managed-identity based — no Azure passwords or client secrets are
stored anywhere.**

> Agent/operator deep-dive: see [`CLAUDE.md`](./CLAUDE.md).

## What it does

For every onboarded repo it creates:

1. A **resource group** `rg-<repo>` (region from `repos.json`, default
   `swedencentral`).
2. An Entra **app registration + service principal** `sp-<repo>-github` with
   **federated (OIDC) credentials** for the repo's `main` branch — no secret.
3. An **Owner** role assignment for that SP scoped to **`rg-<repo>` only** —
   least-privilege, no access to any other resource group.
4. A **GitHub repo** scaffolded from a starter template (optional), with the
   `AZURE_*` secrets and the Actions variables the template workflows consume.

Each onboarded repo is then **self-deploying**: its own workflows build Bicep
and deploy into its own resource group using its own SP.

```
Azure-infrastructure (this repo)
  └── SP: sp-azure-infrastructure-github
        ├── Owner on the subscription (creates RGs, assigns roles)
        └── Microsoft Graph: Application.ReadWrite.All + AppRoleAssignment.ReadWrite.All

Onboarded repos:
  ├── my-api   → SP sp-my-api-github  → Owner on rg-my-api  (own ACR, Container App, …)
  └── my-site  → SP sp-my-site-github → Owner on rg-my-site (Static Web App, …)
```

## Config: `repos.json`

Single source of truth. Each entry is a plain string (empty repo, no template)
or an object selecting a template:

```jsonc
{
  "gitHubOrg": "KennethHeine",
  "location": "swedencentral",
  "repos": [
    "legacy-empty-repo",                                  // string = no template
    { "name": "my-api",  "template": "container-app", "auth": true },
    { "name": "my-site", "template": "static-web" }
  ]
}
```

`template`: `container-app` | `static-web` | `none`. `auth` (container-app only,
default **true**) toggles Entra built-in auth. Schema: `repos.schema.json`.
Onboarding is **idempotent** — re-running never duplicates resources.

## Starter templates

| Template | Source | What you get |
|----------|--------|--------------|
| `container-app` | [`KennethHeine/template-container-app`](https://github.com/KennethHeine/template-container-app) | Azure Container App (scale-to-zero, Log Analytics), **its own per-repo ACR** with image pull via a user-assigned managed identity, secret-less **Entra Easy Auth** (default on). |
| `static-web` | [`KennethHeine/template-static-web`](https://github.com/KennethHeine/template-static-web) | Next.js static export on Azure Static Web Apps (prod + PR previews). |

Each `container-app` repo gets **its own** container registry inside `rg-<repo>`
— there is no shared registry, so image push/pull is fully isolated per repo.

## Operating it

### Add a repo
Run **Add Repo** (`add-repo.yml`) from the Actions tab, or:

```bash
gh workflow run add-repo.yml --repo KennethHeine/Azure-infrastructure \
  -f name=my-api -f template=container-app -f auth=true
```

It appends the entry to `repos.json` and pushes to `main` (using
`AUTOMATION_GITHUB_TOKEN`), which triggers **Onboard Repositories**.

### Decommission a repo
Run **Decommission Repo** (`decommission-repo.yml`) — you must type the repo
name into `confirm`. It removes the `repos.json` entry, deletes `rg-<repo>`
(including the repo's ACR + images, Container App, identity, etc.), the SP, any
Entra apps the SP owns (e.g. the Easy Auth app), and — per the `github_repo`
input — **keeps**, **archives** (read-only), or **deletes** the GitHub repo.

### Manually
```powershell
# All repos from repos.json (needs az login + AUTOMATION_GITHUB_TOKEN):
./scripts/process-repos.ps1 -ConfigFile ./repos.json

# A single repo:
./scripts/create-repo-infrastructure.ps1 -GitHubRepo my-api -Template container-app
```

## One-time setup

```powershell
# Logged in as Global Admin / Privileged Role Admin (for admin consent):
./scripts/setup-service-principal.ps1
```

Creates `sp-azure-infrastructure-github` with **Owner** on the subscription and
Microsoft Graph **`Application.ReadWrite.All`** + **`AppRoleAssignment.ReadWrite.All`**,
plus a `main`-branch federated credential. Add the printed `AZURE_CLIENT_ID`,
`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` as repo secrets, plus
`AUTOMATION_GITHUB_TOKEN` (see below).

## The automation token

`AUTOMATION_GITHUB_TOKEN` is a classic PAT with `repo` (+ `workflow`, and
`delete_repo` if decommission should delete repos). Onboarding validates it up
front (`scripts/test-automation-token.ps1`); rotate it with
`scripts/rotate-automation-token.ps1`.

## Scripts

| Script | Purpose |
|---|---|
| `setup-service-principal.ps1` | One-time setup of this repo's own SP |
| `create-repo-infrastructure.ps1` | Onboard a single repo (RG + SP + OIDC + GitHub repo) |
| `process-repos.ps1` | Onboard every repo in `repos.json` |
| `decommission-repo.ps1` | Tear down one repo's footprint |
| `test-automation-token.ps1` | Validate `AUTOMATION_GITHUB_TOKEN` |
| `rotate-automation-token.ps1` | Rotate `AUTOMATION_GITHUB_TOKEN` |
| `set-github-secrets.ps1` | Set this repo's `AZURE_*` secrets |

## Workflows

| Workflow | Trigger | Purpose |
|---|---|---|
| `onboard-repos.yml` | push to `repos.json` on main, manual | Provision/refresh all repos |
| `add-repo.yml` | manual (inputs) | Add an entry to `repos.json` → triggers onboarding |
| `decommission-repo.yml` | manual (inputs + confirm) | Full teardown of one repo |
| `dns-deploy.yml` | push to `dns/**`, manual | Deploy the kscloud.io DNS zone (creates `rg-dns`) |

## Required secrets (on this repo)

`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (the onboarding SP)
and `AUTOMATION_GITHUB_TOKEN`.
