# Azure-infrastructure — Agent & Operator Guide

This repository is the **control plane** for Kenneth's Azure + GitHub estate. It
onboards new application repositories, provisions their isolated Azure footprint
(each repo gets its own resource group and, for container apps, its own
registry), and provides one-click workflows to add or decommission repos.
Everything is OIDC / managed-identity based — **no Azure passwords or client
secrets are stored anywhere.**

## Mental model

```
repos.json  ──push to main──►  Onboard Repositories workflow
                                   └─ scripts/process-repos.ps1
                                        └─ scripts/create-repo-infrastructure.ps1  (per repo)
                                             ├─ rg-<repo>                    (resource group)
                                             ├─ sp-<repo>-github             (Entra app + SP)
                                             ├─ OIDC federated creds         (main + PRs)
                                             ├─ Owner on rg-<repo>
                                             ├─ GitHub repo                  (from a template)
                                             ├─ secrets: AZURE_CLIENT_ID/TENANT_ID/SUBSCRIPTION_ID
                                             └─ variables: RESOURCE_GROUP, ENABLE_AUTH (container-app)
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
  "location": "swedencentral",
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
| `container-app` | [`KennethHeine/template-container-app`](https://github.com/KennethHeine/template-container-app) | Azure Container App, **scale-to-zero**, Log Analytics, **its own per-repo ACR** with image pull via a user-assigned managed identity granted AcrPull (all declared in the template's Bicep, in `rg-<repo>`), secret-less **Entra Easy Auth** (default on), `deploy-infra` + `deploy-app` workflows. `deploy-app` builds + pushes the image on the runner and updates the app. |
| `static-web` | [`KennethHeine/template-static-web`](https://github.com/KennethHeine/template-static-web) | Next.js static export → **Azure Static Web Apps**, open/public, `deploy-infra` + `deploy` (prod + PR preview) workflows |

New repos are created with `gh repo create --template`. Templated repos keep
their own README/AGENTS.md/CLAUDE.md (the onboarding doc-seeding is skipped for them).

## Per-repo Azure Container Registry

There is **no shared registry**. Each `container-app` repo provisions **its own
ACR inside `rg-<repo>`**, declared in the template's `infra/main.bicep`
(`KennethHeine/template-container-app`), so image push/pull is fully isolated
per repo.

Access model (least-privilege, all within `rg-<repo>` — no cross-RG grants):
- The repo's SP is **Owner of `rg-<repo>`**, so it can create the ACR and push
  images (via `az acr login`) with no extra role assignment.
- The Container App pulls with a **user-assigned managed identity** granted
  **AcrPull** on that ACR. The identity, the ACR, and the AcrPull role
  assignment are all created declaratively in the template's Bicep (the SP can
  assign roles in its own RG, so no imperative pre-step is needed).
- ACR has **admin user disabled** — identity-based access only, no secrets.

This replaced an earlier design with a single shared ACR in `rg-shared` plus a
constrained RBAC-Admin/ABAC delegation; per-repo registries remove the
cross-repo image isolation gaps and the cross-RG delegation entirely.

## Entra Easy Auth (container-app repos)

Container-app repos with `auth: true` get secret-less **Entra built-in auth**. The
auth Entra application is created **at deploy time** by the repo's own
`deploy-infra` workflow via the Microsoft Graph Bicep extension, authenticated by
the Container App's managed identity (federated credential — no client secret).

For a repo's SP to create that app, it needs the Microsoft Graph
**`Application.ReadWrite.OwnedBy`** permission. Onboarding grants it automatically
(Step 5b of `create-repo-infrastructure.ps1`). That works because the central
onboarding SP holds **`AppRoleAssignment.ReadWrite.All`** (granted by
`setup-service-principal.ps1`), which lets it delegate app roles to repo SPs.

So the chain is: `setup-service-principal.ps1` → onboarding SP can grant app roles
→ onboarding grants each auth repo's SP `Application.ReadWrite.OwnedBy` → that repo's
deploy creates its own Easy Auth app. The Easy Auth **token store is not enabled**
(it requires a backing blob-storage SAS URL this template doesn't provision).

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
into `confirm`. It removes the repos.json entry and deletes `rg-<repo>` (which
includes the repo's own ACR + images), the SP, **any Entra apps the SP owns
(e.g. the Easy Auth app)**, and — per the `github_repo` input — **keeps**,
**archives** (read-only), or **deletes** the GitHub repo.

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
| `dns-deploy.yml` | push to `dns/**`, manual | Deploy the kscloud.io DNS zone (creates `rg-dns`) |

## Required secrets (on this repo)

`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (the central
onboarding SP `sp-azure-infrastructure-github`), and `AUTOMATION_GITHUB_TOKEN`.

The onboarding SP (configured by `setup-service-principal.ps1`) has: **Owner** on
the subscription, and Microsoft Graph **`Application.ReadWrite.All`** (create repo
SPs) + **`AppRoleAssignment.ReadWrite.All`** (delegate `Application.ReadWrite.OwnedBy`
to repo SPs for Easy Auth). Re-run that script if these need to be (re)granted.

## Conventions for agents

- **Bicep only**, deployed via GitHub Actions — never create Azure resources by
  hand or with ad-hoc CLI in the portal.
- Keep everything **idempotent** and **scoped** (per-repo resources — including
  each container-app repo's own ACR — live in `rg-<repo>`; estate-wide things
  like the DNS zone live in their own RG, e.g. `rg-dns`).
- **No stored credentials** — OIDC federated identity for CI, managed identities
  for runtime.
- PowerShell scripts target **pwsh 7+**; validate edits with
  `[Parser]::ParseFile(...)` and Bicep with `az bicep build`.
- After changing onboarding logic, prefer validating against a throwaway repo via
  the Add/Decommission workflows rather than an existing one.
