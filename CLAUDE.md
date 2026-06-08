# Azure-infrastructure — Agent & Operator Guide

This repository is the **control plane** for Kenneth's Azure + GitHub estate. It
onboards new application repositories, provisions their isolated Azure footprint,
owns the shared container registry, and provides one-click workflows to add or
decommission repos. Everything is OIDC / managed-identity based — **no Azure
passwords or client secrets are stored anywhere.**

## Mental model

```
repos.json  ──push to main──►  Onboard Repositories workflow
                                   └─ scripts/process-repos.ps1
                                        └─ scripts/create-repo-infrastructure.ps1  (per repo)
                                             ├─ rg-<repo>                    (resource group)
                                             ├─ sp-<repo>-github             (Entra app + SP)
                                             ├─ OIDC federated creds         (main + PRs)
                                             ├─ Owner on rg-<repo>
                                             ├─ shared-ACR grants            (container-app repos)
                                             ├─ GitHub repo                  (from a template)
                                             ├─ secrets: AZURE_CLIENT_ID/TENANT_ID/SUBSCRIPTION_ID
                                             └─ variables: RESOURCE_GROUP, ACR_*, ENABLE_AUTH
```

Each onboarded repo is **self-deploying**: its own `deploy-infra` / `deploy-app`
(or SWA) workflows build Bicep and deploy into **its own resource group** using
the service principal this repo created. The SP is Owner on `rg-<repo>` and
nothing else.

## Config: `repos.json`

The single source of truth. Each entry is either a plain string (empty repo, no
template) or an object selecting a template:

```jsonc
{
  "gitHubOrg": "KennethHeine",
  "location": "norwayeast",
  "repos": [
    "legacy-empty-repo",                                   // string = no template
    { "name": "my-api",  "template": "container-app", "auth": true },
    { "name": "my-site", "template": "static-web" }
  ]
}
```

`template`: `container-app` | `static-web` | `none`. `auth` (container-app only,
default **true**) toggles Entra built-in auth. Schema: `repos.schema.json`.
Onboarding is **idempotent** — re-running never duplicates resources.

## Templates (GitHub template repositories)

| Template | Repo | What you get |
|----------|------|--------------|
| `container-app` | [`KennethHeine/template-container-app`](https://github.com/KennethHeine/template-container-app) | Azure Container App, **scale-to-zero**, Log Analytics, image pull from the **shared ACR via a user-assigned managed identity**, secret-less **Entra Easy Auth** (default on, token store enabled), `deploy-infra` + `deploy-app` workflows |
| `static-web` | [`KennethHeine/template-static-web`](https://github.com/KennethHeine/template-static-web) | Next.js static export → **Azure Static Web Apps**, open/public, `deploy-infra` + `deploy` (prod + PR preview) workflows |

New repos are created with `gh repo create --template`. Templated repos keep
their own README/AGENTS.md/CLAUDE.md (the onboarding doc-seeding is skipped for them).

## Shared Azure Container Registry

`shared/main.bicep` provisions one ACR (Standard, admin user disabled) in
`rg-shared`, deployed by the **Deploy Shared Infrastructure** workflow
(`deploy-shared.yml`). It must exist before onboarding a `container-app` repo.

Access model (least-privilege, validated against Microsoft Learn):
- Each container-app repo's SP gets **AcrPush** (push images) on the ACR.
- Each SP also gets **Role Based Access Control Administrator** scoped to the ACR
  with an **ABAC condition constraining it to assign only the AcrPull role** — so
  the app's own deploy can grant *its* Container App's user-assigned managed
  identity pull access, and nothing more. (RBAC Admin + condition is the MS-
  recommended delegation, narrower than User Access Administrator.)
- Container Apps pull images using a **user-assigned managed identity** + AcrPull
  — no admin credentials, no secrets.

> Note: ACR is migrating toward "ABAC-enabled" mode where `AcrPull`/`AcrPush` are
> replaced by `Container Registry Repository Reader/Writer` + `Catalog Lister`.
> This registry uses the classic RBAC mode where the familiar roles work. Revisit
> if/when migrating.

## Operating it

### Add a repo (preferred: the workflow)
Run **Add Repo** (`add-repo.yml`) from the Actions tab or:
```bash
gh workflow run add-repo.yml --repo KennethHeine/Azure-infrastructure \
  -f name=my-api -f template=container-app -f auth=true
```
It edits `repos.json` and pushes to main (using `AUTOMATION_GITHUB_TOKEN`, so the
push triggers onboarding). Then watch **Onboard Repositories**.

### Decommission a repo
Run **Decommission Repo** (`decommission-repo.yml`) — you must type the repo name
into `confirm`. It removes the repos.json entry and deletes `rg-<repo>`, the SP,
the shared-ACR grants + image, and (if `delete_github_repo=true`) the GitHub repo.

### Manually
`pwsh ./scripts/process-repos.ps1 -ConfigFile ./repos.json` (needs `az login` +
`AUTOMATION_GITHUB_TOKEN`).

## The automation token

`AUTOMATION_GITHUB_TOKEN` (repo secret) is a classic PAT with `repo` (+ `workflow`,
and `delete_repo` if you want decommission to delete repos) scope. The onboarding
workflow validates it up front (`scripts/test-automation-token.ps1`). When it
expires, rotate with `scripts/rotate-automation-token.ps1` (prints the create-token
URL, validates, writes the secret, optionally re-runs onboarding).

## Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `onboard-repos.yml` | push to `repos.json` on main, manual | Provision/refresh all repos |
| `add-repo.yml` | manual (inputs) | Add an entry to repos.json → triggers onboarding |
| `decommission-repo.yml` | manual (inputs + confirm) | Full teardown of one repo |
| `deploy-shared.yml` | push to `shared/**`, manual | Deploy the shared ACR |
| `dns-deploy.yml` | push to `dns/**`, manual | Deploy the kscloud.io DNS zone |

## Required secrets (on this repo)

`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (the central
subscription-Owner SP used for onboarding/teardown), and `AUTOMATION_GITHUB_TOKEN`.

## Conventions for agents

- **Bicep only**, deployed via GitHub Actions — never create Azure resources by
  hand or with ad-hoc CLI in the portal.
- Keep everything **idempotent** and **scoped** (per-repo resources in `rg-<repo>`;
  shared things in `rg-shared`).
- **No stored credentials** — OIDC federated identity for CI, managed identities
  for runtime.
- PowerShell scripts target **pwsh 7+**; validate edits with
  `[Parser]::ParseFile(...)` and Bicep with `az bicep build`.
- After changing onboarding logic, prefer validating against a throwaway repo via
  the Add/Decommission workflows rather than an existing one.
