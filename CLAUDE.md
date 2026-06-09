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
                                        ├─ scripts/register-providers.ps1          (once: providers.json)
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

## Config: `providers.json`

The subscription-level **resource providers** the estate needs (Container Apps,
Container Instances, ACR, Storage, Log Analytics, Managed Identity, Static Web
Apps, DNS, Insights). A provider that isn't registered fails only at *deploy
time* with `The subscription is not registered to use namespace '...'` — e.g. the
`claude-runner` app couldn't start its per-session ACI until
`Microsoft.ContainerInstance` was registered. Keeping the list here puts that
under code control.

`scripts/register-providers.ps1` reads `providers.json` and registers any that
aren't already registered (idempotent; waits for completion unless `-NoWait`).
`process-repos.ps1` calls it **once at the start of onboarding** — before any
repo is processed — so a repo's first Bicep deploy never trips over an
unregistered provider. Add a namespace to `providers.json` whenever a template
starts using a new Azure resource type. Schema: `providers.schema.json`.

## Templates (GitHub template repositories)

| Template | Repo | What you get |
|----------|------|--------------|
| `container-app` | [`KennethHeine/template-container-app`](https://github.com/KennethHeine/template-container-app) | Azure Container App, **scale-to-zero**, Log Analytics, **its own per-repo ACR** with image pull via a user-assigned managed identity granted AcrPull (all declared in the template's Bicep, in `rg-<repo>`), secret-less **Entra Easy Auth** (default on), optional **custom domain** (managed cert), `deploy-infra` + `deploy-app` workflows that are **thin callers of the reusable workflows below**. `deploy-app` builds the image with **`az acr build`** (cloud build) and updates the app. |
| `static-web` | [`KennethHeine/template-static-web`](https://github.com/KennethHeine/template-static-web) | Next.js static export → **Azure Static Web Apps**, open/public, `deploy-infra` + `deploy` (prod + PR preview) workflows |

New repos are created with `gh repo create --template`. Templated repos keep
their own README/AGENTS.md/CLAUDE.md (the onboarding doc-seeding is skipped for them).

## Reusable container-app workflows (single source of truth)

The container-app deploy logic lives **here**, in two reusable workflows, so it's
maintained in one place for every container-app repo instead of being copy-pasted
into each one:

| Reusable workflow | What it does |
|-------------------|--------------|
| `.github/workflows/container-app-deploy-infra.yml` | Deploys the repo's `infra/main.bicep` (image-preservation on re-deploy, optional custom-domain hostname registration → bind, post-deploy re-auth, conditional Easy-Auth CLI pre-authorization). |
| `.github/workflows/container-app-deploy-app.yml` | Builds images with **`az acr build`** (cloud build — no Docker on the runner) and points the Container App at the new image. `setup` → `build-app` ‖ `build-extra` (matrix, parallel) → `deploy`. Input `extra_images` (JSON `[{suffix,dockerfile,context}]`) builds extra images, e.g. a sidecar/runner image, each as its own parallel job. |

Each container-app repo keeps only **thin callers** (`deploy-infra.yml` /
`deploy-app.yml`) that `uses:` these `@main` with `secrets: inherit`:

```yaml
jobs:
  deploy:
    uses: KennethHeine/Azure-infrastructure/.github/workflows/container-app-deploy-app.yml@main
    secrets: inherit
    # with: { extra_images: '[{"suffix":"-runner","dockerfile":"runner/Dockerfile","context":"."}]' }
```

Pinned to **`@main`** on purpose: an edit here propagates to every repo on its
next run. The caller still declares its own `on:` triggers and
`permissions: { id-token: write, contents: read }` (OIDC permission must be
granted by the caller).

**Bicep contract** — for a repo to use the reusable workflows, its
`infra/main.bicep` must accept params **`appName`**, **`image`**,
**`bindCustomDomain`** and emit outputs **`containerAppName`**,
**`containerAppFqdn`**, **`authEnabled`**, **`authAppClientId`**,
**`authAppUserImpersonationScopeId`**, **`azureCliClientId`**. `appName` unset (or
`"app"`) → the workflow derives the sanitized repo name; names derive as
`ca-/cae-/log-/id-<appName>`. RBAC the app's identity needs at runtime belongs in
the Bicep (e.g. `claude-runner` grants its UAMI Contributor on `rg-<repo>` in
Bicep so it can manage per-session ACI), **not** as an imperative workflow step.

## Per-repo Azure Container Registry

There is **no shared registry**. Each `container-app` repo provisions **its own
ACR inside `rg-<repo>`**, declared in the template's `infra/main.bicep`
(`KennethHeine/template-container-app`), so image push/pull is fully isolated
per repo.

Access model (least-privilege, all within `rg-<repo>` — no cross-RG grants):
- The repo's SP is **Owner of `rg-<repo>`**, so it can create the ACR and build/push
  images (via `az acr build` — cloud build) with no extra role assignment.
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

### Manage DNS records (kscloud.io)
`dns/records.json` is the **single source of truth** for the zone; `dns/main.bicep`
projects it into Azure DNS record sets (looped by type). Add or remove records
with the workflows — never edit the zone by hand:
```bash
gh workflow run add-dns-record.yml --repo KennethHeine/Azure-infrastructure \
  -f type=CNAME -f name=blog -f value=my-site.azurestaticapps.net
gh workflow run remove-dns-record.yml --repo KennethHeine/Azure-infrastructure \
  -f type=CNAME -f name=blog
```
Each edits `records.json` and pushes (via `AUTOMATION_GITHUB_TOKEN`), triggering
**Deploy DNS Zone**. That workflow applies the Bicep and then **reconciles**:
because ARM incremental deploys never delete, a prune step removes any record set
in the zone not present in `records.json` (apex `NS`/`SOA` are always preserved).
MX values are `'<preference> <exchange>'` (e.g. `0 mail.example.com`).

### Manage Exchange Online (mail tenant)
Exchange Online has **no ARM/Bicep surface**, so it's managed the same way the DNS
zone is — declaratively, from code. `exchange/config.json` is the **single source of
truth** (currently: DKIM signing state per domain); `scripts/deploy-exchange.ps1`
reconciles it into Exchange Online idempotently via the **Deploy Exchange Online
Config** workflow (push to `exchange/**`, or manual).

**Auth is credential-free — no certificate, no stored secret.** Exchange Online
PowerShell can't consume a GitHub OIDC token directly, but `Connect-ExchangeOnline`
accepts `-AccessToken`. So the workflow signs in the **same OIDC SP** used everywhere
else (`azure/login`), mints an Exchange token off it
(`az account get-access-token --resource https://outlook.office365.com`), and connects
app-only. The SP carries the Exchange RBAC it needs via two grants added by
`setup-service-principal.ps1`: the **`Exchange.ManageAsApp`** app role (on *Office 365
Exchange Online*) and the **Exchange Administrator** directory role (which populates
the RBAC claim EXO reads from the token). A managed identity would be just another
SP with the same roles — `-AccessToken` lets the existing federated SP do the job
without IMDS or a cert.

Reconciliation is **additive** (unlike the DNS pruner): only domains listed in
`config.json` are touched; an unlisted domain is never disabled. A domain whose
selector CNAMEs haven't propagated yet can't be enabled (EXO reports `CnameMissing`)
— that's reported as **pending**, not a failure, and self-heals on the next run. DKIM
needs both halves: the selector CNAMEs in `dns/records.json` **and** the enable here.

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
| `dns-deploy.yml` | push to `dns/**`, manual | Deploy the kscloud.io DNS zone (creates `rg-dns`); applies `dns/records.json` then prunes stale records |
| `add-dns-record.yml` | manual (inputs) | Upsert a record in `dns/records.json` → triggers Deploy DNS Zone |
| `remove-dns-record.yml` | manual (inputs) | Remove a record from `dns/records.json` → triggers Deploy DNS Zone |
| `exchange-deploy.yml` | push to `exchange/**`, manual | Reconcile Exchange Online config (DKIM signing) from `exchange/config.json`, app-only via the OIDC SP |

## Required secrets (on this repo)

`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (the central
onboarding SP `sp-azure-infrastructure-github`), and `AUTOMATION_GITHUB_TOKEN`.

The onboarding SP (configured by `setup-service-principal.ps1`) has: **Owner** on
the subscription, Microsoft Graph **`Application.ReadWrite.All`** (create repo
SPs) + **`AppRoleAssignment.ReadWrite.All`** (delegate `Application.ReadWrite.OwnedBy`
to repo SPs for Easy Auth), and for managing the mail tenant as code: **Office 365
Exchange Online `Exchange.ManageAsApp`** + the **Exchange Administrator** directory
role. Re-run that script if these need to be (re)granted.

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
