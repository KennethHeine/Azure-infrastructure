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
default **true**) toggles Entra built-in auth. `preview` (default **false**)
opts the repo into **per-branch preview environments** (see that section below).
Schema: `repos.schema.json`. Onboarding is **idempotent** — re-running never
duplicates resources.

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

## Config: `role-grants.json`

Estate-wide **RBAC grants that exceed a single repo's resource-group scope**.
Repo-scoped RBAC belongs in each repo's own Bicep (its SP is Owner of its RG);
grants a repo SP can't make itself are declared here and applied by the
onboarding SP (subscription Owner) via `scripts/apply-role-grants.ps1` —
`process-repos.ps1` runs it right after provider registration. Idempotent; an
identity whose repo hasn't deployed yet is a warning, not a failure (re-run
**Onboard Repositories** after that repo's infra deploy). Schema:
`role-grants.schema.json`. Two `scope`s: `subscription`, or `resource` (a
single resource OUTSIDE the identity's repo RG, named by `scopeResourceId`).

Current grants:
- `claude-runner` **coder-session identity** (`id-claude-runner-session-coder`)
  → subscription **Reader** + **Log Analytics Reader** — read-only estate
  visibility for the autonomous coding agent (still can't change Azure outside
  GitHub Actions).
- `claude-runner-test` **broker** (`id-claude-runner-test`) → **Virtual Machine
  User Login** (grants the HybridConnectivity relay access every `az ssh arc`
  needs) + **Azure Connected Machine Resource Administrator** (Run Command),
  scoped to the **`dockhost`** Azure Arc machine (rg-homelab) — lets the test
  broker SSH-over-Arc into the homelab and run commands, for the experimental
  homelab/Docker session backend. The broker is a managed identity, and Entra
  SSH certs are issued only to interactive users, so it authenticates with an
  **ephemeral local-user key** (regenerated each boot, pushed via Run Command,
  never stored). Sandbox-only.
- `claude-runner` **PROD broker** (`id-claude-runner`) → the same two roles on
  the **`dockhost`** Arc machine — the production form of the test-broker grant
  above, for the homelab session backend now promoted to prod.

## Templates (GitHub template repositories)

| Template | Repo | What you get |
|----------|------|--------------|
| `container-app` | [`KennethHeine/template-container-app`](https://github.com/KennethHeine/template-container-app) | Azure Container App, **scale-to-zero**, Log Analytics, **its own per-repo ACR** with image pull via a user-assigned managed identity granted AcrPull (all declared in the template's Bicep, in `rg-<repo>`), secret-less **Entra Easy Auth** (default on), optional **custom domain** (managed cert), `deploy-infra` + `deploy-app` workflows that are **thin callers of the reusable workflows below**. `deploy-app` builds the image with **`az acr build`** (cloud build) and updates the app. |
| `static-web` | [`KennethHeine/template-static-web`](https://github.com/KennethHeine/template-static-web) | Next.js static export → **Azure Static Web Apps**, open/public, `deploy-infra` + `deploy` (prod + PR preview) workflows that are **thin callers of the reusable workflows below**. The SWA deployment token is **fetched at deploy time via OIDC** — no stored secret, no manual onboarding step. |

New repos are created with `gh repo create --template`. Templated repos keep
their own README/AGENTS.md/CLAUDE.md (the onboarding doc-seeding is skipped for them).

## Reusable container-app workflows (single source of truth)

The container-app deploy logic lives **here**, in two reusable workflows, so it's
maintained in one place for every container-app repo instead of being copy-pasted
into each one:

| Reusable workflow | What it does |
|-------------------|--------------|
| `.github/workflows/container-app-deploy-infra.yml` | Deploys the repo's `infra/main.bicep` (image-preservation on re-deploy, optional custom-domain hostname registration → bind, post-deploy re-auth, conditional Easy-Auth CLI pre-authorization). |
| `.github/workflows/container-app-deploy-app.yml` | Builds images with **`az acr build`** (cloud build — no Docker on the runner) and points the Container App at the new image. `setup` → `build-app` ‖ `build-extra` (matrix, parallel) → `deploy` → `cleanup`. Input `extra_images` (JSON `[{suffix,dockerfile,context}]`) builds extra images, e.g. a sidecar/runner image, each as its own parallel job. The `cleanup` job prunes stale images from the repo's ACR after every successful deploy (Basic SKU has only 10 GiB included); it keeps everything referenced by active Container App revisions / ACI groups / Container Apps jobs in the RG, `latest`, the newest `image_retention_count` (default 5) tagged manifests per repository, any non-git-sha tag, multi-arch index children, and anything < 24 h old — and aborts without deleting if the in-use query fails. Cleanup failure never fails the deploy run (`continue-on-error`). |

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

## Reusable static-web workflows (single source of truth)

The static-web deploy logic also lives **here**, in two reusable workflows, so
every static frontend repo shares one source:

| Reusable workflow | What it does |
|-------------------|--------------|
| `.github/workflows/static-web-deploy-infra.yml` | Deploys the repo's `infra/main.bicep` into its resource group. On `pull_request` (with `whatif: true`) posts an informational what-if to the job summary instead of deploying. Inputs: `resource_group`, `bicep_param` (default `infra/main.bicepparam`), `whatif`. |
| `.github/workflows/static-web-deploy.yml` | Builds the app and deploys to Azure Static Web Apps. **Fetches the SWA deployment token at deploy time via OIDC** (`az staticwebapp secrets list`) — no `AZURE_STATIC_WEB_APPS_API_TOKEN` secret to store. Production on push; per-PR preview on `pull_request` (closed on PR close). Inputs: `app_dir` (default `web`), `resource_group`, optional quality gate `test_command` + `run_e2e` (Playwright). Deploy steps are skipped for Dependabot (the gate still runs). |

Each static-web repo keeps only **thin callers** (`deploy-infra.yml` /
`deploy.yml`) pinned `@main` with `secrets: inherit`:

```yaml
jobs:
  deploy:
    uses: KennethHeine/Azure-infrastructure/.github/workflows/static-web-deploy.yml@main
    secrets: inherit
    with:
      app_dir: static-web-app
      # test_command: 'npm run lint && npm run format:check && npm test'
      # run_e2e: true
```

The caller declares its own `on:` triggers (push to app paths, `pull_request`
incl. `closed`, dispatch) and `permissions: { id-token: write, contents: read,
pull-requests: write }`. The app contract: an npm project under `app_dir` whose
`npm run build` emits `<app_dir>/out`. Because the token is fetched at deploy
time, **the old one-time `AZURE_STATIC_WEB_APPS_API_TOKEN` setup step is gone.**

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
- **Image lifecycle**: registries are Basic SKU (10 GiB included) and ACR
  retention policies are Premium-only, so the reusable `deploy-app` workflow's
  `cleanup` job prunes stale manifests after every successful deploy instead
  (images are only ever *added* by deploy runs, so cleanup-on-deploy bounds
  growth). It never deletes anything in use — see the workflow table above.

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

## Per-branch preview environments (opt-in)

A container-app repo with `"preview": true` in `repos.json` gets an **isolated
sandbox** so non-`main` branches can deploy without any path to prod. Today only
`claude-runner` opts in; the OIDC/routing mechanism is generic.

**Why a separate identity.** A GitHub OIDC token doesn't carry its branch into
Azure role scope, so isolation can't come from the credential — it comes from a
**separate SP**:

- Onboarding (`create-repo-infrastructure.ps1`, Step 8c) creates, alongside the
  prod footprint: `rg-<repo>-preview`, `sp-<repo>-preview-github` (**Owner of
  `rg-<repo>-preview` only** — it physically can't touch prod), a **flexible
  federated credential** trusting **any branch** (`claims['sub'] matches
  'repo:<org>/<repo>:ref:refs/heads/*'` — a wildcard FIC, which for app
  registrations is **Graph beta only**, so it's created via `az rest` against
  `beta/applications/{objectId}/federatedIdentityCredentials`, not
  `az ad app federated-credential create`), the same Graph
  `Application.ReadWrite.OwnedBy` grant the prod SP gets (so preview Easy Auth
  works), and the repo secret **`AZURE_CLIENT_ID_PREVIEW`** + variable
  **`RESOURCE_GROUP_PREVIEW`**.
- The prod SP is unchanged (`main` + PRs, Owner of `rg-<repo>`).

**Routing (reusable workflows).** Both `container-app-deploy-infra.yml` and
`container-app-deploy-app.yml` take a `preview` input (default false). When a
caller sets it AND `github.ref != refs/heads/main`, every `azure/login` uses the
preview SP (inline ternary — secrets can't be job outputs) and the deploy targets
`vars.RESOURCE_GROUP_PREVIEW`. Preview also forces `customDomain=''` (never binds
the prod hostname — preview is reached on its default FQDN) and `enableAlerts=false`
(a fresh env has no `ContainerAppConsoleLogs_CL` table yet, which would fail the
alert-rule deploy). `deploy-app` forces the app to **`--min-replicas 0`** so the
sandbox scales to zero. Non-preview callers resolve to the prod SP/RG — byte-identical.

**The caller opts in** (`claude-runner`'s `deploy-infra.yml`/`deploy-app.yml`):
`with: { preview: true }`, a `test/**` push trigger, and the prod-only `verify`
job is skipped on non-`main`. So **push a `test/**` branch → preview; `main` → prod.**
deploy-app concurrency is keyed per `github.ref` so prod and preview deploys
never cancel each other.

**Base-split + preview ACR.** Because `claude-runner`'s slim Dockerfiles `FROM`
its base images, a fresh (empty) preview ACR can't resolve them and
`prime-base-images` can't import internal `*-base` from Docker Hub. So
`claude-runner`'s `build-base-images.yml` has a **`preview-seed`** job that builds
the bases into the preview ACR too, as the preview SP (gated on
`RESOURCE_GROUP_PREVIEW`).

**Cost.** Compute scales to zero; the only standing cost is the preview ACR
(~$5/mo Basic). Infra is kept standing (no idle teardown) for fast feedback — a
test iteration runs only `deploy-app` (~1-2 min), not `deploy-infra`. The
per-deploy `cleanup` job prunes the preview ACR's image tags like prod's.
`decommission-repo.ps1` (Step 3c) tears the whole preview footprint down with the
repo. Full design + history: `PLAN-preview-env.md`.

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
(e.g. the Easy Auth app)**, **the preview footprint if any (`sp-<repo>-preview-github`
+ `rg-<repo>-preview`, Step 3c)**, and — per the `github_repo` input — **keeps**,
**archives** (read-only), or **deletes** the GitHub repo.

### Manually
`pwsh ./scripts/process-repos.ps1 -ConfigFile ./repos.json` (needs `az login` +
`AUTOMATION_GITHUB_TOKEN`).

### Manage DNS records (kscloud.io)
The zone's records are split across **two source files** by blast radius, and
`dns/main.bicep` projects their **union** into Azure DNS record sets (looped by
type):

| File | Holds | Changed via |
|------|-------|-------------|
| `dns/records.platform.json` | mail / M365 foundation (MX, SPF, DKIM, DMARC, autodiscover, enrollment). Carries the canonical `zoneName`. | **PR only** — high blast radius |
| `dns/records.app.json` | app custom domains (CNAMEs + validation TXTs). No `zoneName`. | the Add/Remove DNS Record workflows |

So app-record churn can't touch the mail records. Add or remove **app** records
with the workflows — never edit the zone by hand:
```bash
gh workflow run add-dns-record.yml --repo KennethHeine/Azure-infrastructure \
  -f type=CNAME -f name=blog -f value=my-site.azurestaticapps.net
gh workflow run remove-dns-record.yml --repo KennethHeine/Azure-infrastructure \
  -f type=CNAME -f name=blog
```
Each edits `records.app.json` and pushes (via `AUTOMATION_GITHUB_TOKEN`),
triggering **Deploy DNS Zone**. Platform/mail records are edited by PR to
`records.platform.json`. That workflow applies the Bicep and then **reconciles**:
because ARM incremental deploys never delete, a prune step removes any record set
in the zone present in **neither** file (apex `NS`/`SOA` are always preserved).
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
needs both halves: the selector CNAMEs in `dns/records.platform.json` **and** the enable here.

## GitHub App for the claude-runner agent (as code)

The `claude-runner` agent sessions authenticate to GitHub with a **GitHub App**
(short-lived installation tokens; safer than a personal account). GitHub does
not allow creating apps via plain REST/Bicep, so this repo codifies the maximum
GitHub supports — the **app manifest flow**:

| File | Holds |
|------|-------|
| `github-app/manifest.json` | The app definition: name `claude-runner-agent`, no webhook, repository permissions Contents/Actions/Workflows/PRs/Issues **RW** + Metadata R |
| `scripts/create-github-app.ps1` | Drives the manifest flow end-to-end: browser confirm (once) → exchanges the code for app id + private key → uploads the PEM **directly into the claude-runner Key Vault** (`github-app-private-key`) → prints the install link and the `githubAppId` value to set in `claude-runner/infra/main.parameters.json` |

Run it from a machine with a browser + `az login`. Key rotation does **not**
need the script: generate a new key on the app's GitHub page and
`az keyvault secret set` it. To change permissions later, edit them on the app
page (and mirror the change in `manifest.json` so the file stays the truth).

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
| `dns-deploy.yml` | push to `dns/**`, manual | Deploy the kscloud.io DNS zone (creates `rg-dns`); applies the union of `dns/records.platform.json` + `dns/records.app.json` then prunes stale records |
| `add-dns-record.yml` | manual (inputs) | Upsert an app record in `dns/records.app.json` → triggers Deploy DNS Zone |
| `remove-dns-record.yml` | manual (inputs) | Remove an app record from `dns/records.app.json` → triggers Deploy DNS Zone |
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

## Operational gotchas (learned the hard way — read before estate work)

**DNS (kscloud.io):**
- **Never dispatch two DNS-record workflows concurrently.** Both commit to this
  repo's `main`; the loser's push is rejected and its record silently lost.
  Worse, two overlapping **Deploy DNS Zone** runs check out different commits
  and the older run's prune step deletes records the newer one just added.
  Dispatch one record change, wait for its Deploy DNS Zone to finish, then the
  next. Recovery: dispatch `dns-deploy.yml` once, alone, from current HEAD.
- **Verify DNS against the authoritative azure-dns NS, not 8.8.8.8** — public
  resolvers serve stale negative caches for up to the SOA min TTL after a
  prune+recreate. `dig <name> TXT @ns1-05.azure-dns.com` shows truth, and it is
  what Azure's managed-cert validation reads (so binding can succeed while
  8.8.8.8 still shows nothing).
- **Decommissioning a repo does NOT prune its DNS records.** Remove the app's
  CNAME + `asuid.*` TXT entries from `dns/records.app.json` in the same cleanup
  — in ONE atomic commit (see the concurrency hazard above).

**Custom domains (container apps):**
- When the app already exists, deploy-infra registers the hostname AND binds the
  managed cert in the SAME run once `customDomain` is set — so the CNAME +
  `asuid` TXT must be authoritative **before** you push the parameter. (The
  "first pass deploys unbound" note only applies when the app doesn't exist yet.)

**Regions:**
- **Azure Static Web Apps exist in only 5 regions** (centralus, eastus2,
  westus2, westeurope, eastasia) — none in the Nordics. The static-web template
  maps unsupported regions to westeurope; content is edge-served, so no penalty.
- **Resource groups never relocate.** Changing `location` in repos.json only
  affects future RGs; an existing RG must be deleted + recreated (a one-off
  `workflow_dispatch` in the repo running as its own SP can delete its RG, then
  onboarding recreates it). Cognitive Services accounts **soft-delete** with the
  RG and block same-name recreation — recover with `properties.restore: true`
  for one deploy, then revert.
- **Key Vaults also soft-delete** with the RG (default 90-day retention) and
  block same-name recreation with *"A vault with the same name already exists in
  deleted state"*. The container-app template's vault name derives from
  `uniqueString(resourceGroup().id)`, which is **identical for a same-named RG
  recreated later** — so a decommission→re-onboard of the same repo hits this at
  the Key Vault resource. `decommission-repo.ps1` now purges the RG's
  soft-deleted vault(s) (Step 3b) so the name is freed; if you tear an RG down by
  hand, `az keyvault purge --name <v> --location <loc>` yourself (subscription
  Owner scope — a repo SP scoped to its RG cannot purge a subscription-level
  deletedVault).
- **The Easy Auth Entra app has the same soft-delete trap.** `az ad app delete`
  only SOFT-deletes (30-day retention), and the app's `uniqueName` is
  `uniqueString(subscription, rg.id)`-derived — identical for a same-named RG
  recreated later. A lingering soft-deleted app keeps that uniqueName reserved,
  so a re-onboard's Microsoft.Graph Bicep deploy can't recreate it — the
  symptom is the *dependent* resources failing: `authServicePrincipal` →
  *"The language expression property 'appId' doesn't exist"* and
  `authFederatedCredential` → *"Resource '…-auth-…' does not exist"* (NOT a clear
  "name taken" error). `decommission-repo.ps1` now permanently deletes the app
  from `directory/deletedItems` (Step 1). To fix by hand:
  `az rest --method DELETE --url "https://graph.microsoft.com/v1.0/directory/deletedItems/<objectId>"`
  (find it via `…/deletedItems/microsoft.graph.application`; needs Graph
  `Application.ReadWrite.All`).

**Easy Auth:**
- `add-repo` `auth=` writes the **ENABLE_AUTH repo variable**, and the reusable
  deploy-infra passes it as the `enableAuth` parameter override; without the
  variable, `infra/main.parameters.json` (template default **true**) decides.
- To call an Easy-Auth-protected app non-interactively: any same-tenant
  identity can `az account get-access-token --resource <authAppClientId>` and
  send it as a bearer — Easy Auth accepts it (aud/iss match the app
  registration). Works for smoke tests, CI verification, and Playwright
  (`extraHTTPHeaders`).

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
- **Base images through ACR**: container-app Dockerfiles should declare
  `ARG ACR_LOGIN_SERVER=docker.io` and `FROM ${ACR_LOGIN_SERVER}/<path>:<tag>`
  — the reusable deploy-app workflow injects the repo ACR's login server and
  lazily imports/refreshes the base image (Docker Hub anonymous pulls 429
  under ACR's shared egress IP; anonymous cache *rules* are blocked by Azure).
