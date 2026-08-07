# Azure-infrastructure — Agent & Operator Guide

This repository is the **control plane** for Kenneth's Azure + GitHub estate. It
onboards new application repositories, provisions their isolated Azure footprint
(each repo gets its own resource group; container apps share one estate-wide
registry, isolated by Entra ABAC repository permissions), and provides one-click
workflows to add or decommission repos.
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

**`sharedAcr`** (optional) controls the shared-registry grants derived for the
repo by `scripts/derive-acr-grants.ps1`. Omit it and you get the right thing:
enabled for `container-app`, disabled for everything else, with the pull
identity assumed to be `id-<repo>`. Set `false` to derive nothing, or an object
to override:

```jsonc
{ "name": "article-to-speech", "template": "container-app", "auth": true,
  // the template names the identity after appName, not the repo
  "sharedAcr": { "pullIdentities": ["id-articletts"] } },

{ "name": "trading-lab", "template": "none", "auth": true,
  // several pull identities; builds with docker, so it needs no
  // az acr build / az acr import control-plane roles
  "sharedAcr": { "pullIdentities": ["id-trading-lab-lane", "id-trading-lab-dashboard"],
                 "cloudBuild": false } }
```

Add a repo here and its registry access is created for you — see the shared-ACR
section for what gets emitted and why the repo can't grant itself.

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
grants a repo SP can't make itself are applied by the onboarding SP
(subscription Owner) via `scripts/apply-role-grants.ps1`. That script applies
**two** sources:

| Source | What | Where it comes from |
|--------|------|---------------------|
| **Derived** | The shared-ACR grants every container-app repo needs | Generated from `repos.json` by `scripts/derive-acr-grants.ps1` — pure boilerplate keyed off the repo name, so a new repo gets registry access with **zero** config |
| **Declared** | Everything genuinely bespoke | `role-grants.json` (this file) |

Keep `role-grants.json` for the bespoke cases only. If you find yourself writing
a grant whose every field is a function of the repo name, it belongs in the
derivation instead.

`process-repos.ps1` applies grants **twice**: once before the repo loop, and
again after it — the second pass is what lets a brand-new repo's `sp-<repo>-github`
grants land in the *same* onboarding run, since that SP is created inside the
loop. Idempotent; an identity whose repo hasn't deployed yet is a warning, not a
failure (a repo's runtime `id-<repo>` still needs one re-run of **Onboard
Repositories** after its first infra deploy). Schema:
`role-grants.schema.json`. Two `scope`s: `subscription`, or `resource` (a
single resource OUTSIDE the identity's repo RG, named by `scopeResourceId`).

Current grants (`role-grants.json` is the truth — this list is a summary):
- `agent` **broker** (`id-agent`) → *Azure Arc Enabled Kubernetes Cluster User
  Role* on the homelab cluster `dockhost-k3s` in **`rg-homelab`** (moved here
  2026-08-05 — this is the agent platform's homelab session backend). It used to
  live in `rg-claude-runner-preview` as `claude-k8s-preview`: a parked 2026-06-23
  spike (`test/arc-k8s`) that quietly became load-bearing once claude-runner,
  then agent, started sharing it rather than registering a second connection —
  a k8s cluster can be Arc-connected only once. Re-registering it into its
  correct home (alongside the `dockhost` Arc **machine**, which was always here)
  needed a delete + reconnect — there is no RG-move for
  `Microsoft.Kubernetes/connectedClusters` — which mints a NEW OIDC issuer URL;
  every k8s federated credential moved in the same change as this grant.
- `agent` **session identity** (`id-agent-session`) → subscription **Reader** +
  **Log Analytics Reader**, plus **Cost Management Reader**.
- `agent` **local-sysadmin session identity** (`id-agent-session-localsys`) →
  subscription **Reader** + **Log Analytics Reader** + **Cost Management
  Reader** — the same read set as `id-agent-session` above, granted 2026-08-04
  when the local-sysadmin profile absorbed the retired cloud-sysadmin role and
  became sysadmin for cloud AND local. Its Entra directory read is in
  `graph-grants.json`.

(The five `agent` **Key Vault** grants into `rg-claude-runner` — `id-agent` on the
shared `github-app-private-key` vault and the four per-profile `Secrets Officer`
grants — were **removed 2026-08-04**: agent now owns its own per-profile vaults in
`rg-agent`, declared in its own Bicep next to the identities that receive them, so
these cross-RG grants are dead. Note `apply-role-grants.ps1` is additive only, so
removing an entry stops it being re-granted but does **not** revoke the live
assignment — delete those separately, or let them die with the old vaults.)

(The former `dockhost` Arc-machine grants for the `claude-runner` / `claude-runner-test`
brokers — *Virtual Machine User Login* + *Azure Connected Machine Resource Administrator*,
for the SSH-over-Arc `arc:dockhost` session backend — were **removed 2026-06-26**: that
backend was retired in favour of the Arc-enabled k3s (`k8s`) backend, which authenticates
to the cluster with its own Cluster-User grant + a ServiceAccount token, needing no
machine-scoped access. The live assignments were deleted too.)

## Config: `graph-grants.json`

Estate-wide **Microsoft Graph app-role (application permission) grants** to
managed identities — Entra *directory* grants on a resource service principal,
**not** Azure RBAC (that's `role-grants.json`). Only the onboarding SP can create
them: it holds Graph **AppRoleAssignment.ReadWrite.All**; a repo's own SP cannot.
Declared here and applied by `scripts/apply-graph-grants.ps1`, which
`process-repos.ps1` runs right after `apply-role-grants.ps1`. A managed identity's
`principalId` is its service-principal object id, so each grant is POSTed to
`/servicePrincipals/{principalId}/appRoleAssignments`. Idempotent; an identity
whose repo hasn't deployed yet is a warning, not a failure (re-run **Onboard
Repositories** afterwards). Schema: `graph-grants.schema.json`. App-role ids come
from the resource API's permission reference and are constant across tenants
(default resource is Microsoft Graph; override with `resourceAppId`).

Current grants (`graph-grants.json` is the truth — this list is a summary):
- `agent` **coder** and **local-sysadmin** session identities (`id-agent-session`,
  `id-agent-session-localsys`) → Microsoft Graph **Directory.Read.All**
  (application, read-only). Lets estate work resolve principals and inspect app
  registrations; without it `az role assignment list` prints *"Failed to query by
  invoking Graph API"* and shows raw object ids. Note it is **directory-wide read
  across the tenant** — broader than anything in `role-grants.json`. No write
  permission: RBAC and app-registration changes stay in the control plane.
- `agent` **business assistant profile** → Microsoft Graph **Mail.Read**
  (application) on its **unified session identity** `id-agent-session-business`.
  The business profile runs on both backends as ONE identity — attached to the ACI
  container group *and* federated to the business k8s ServiceAccount (`fc-k8s-business`)
  — so this single grant covers both. Read-only mailbox access for the ask-first
  business assistant, app-only (no stored refresh token). The tenant has a single
  mailbox, so no Exchange application access policy is scoped; add one (restricting
  the app to a mail-enabled security group) if more mailboxes are ever added.
  (This grant belonged to claude-runner's equivalent identity until that repo was
  decommissioned 2026-08-05 — Entra auto-revoked the old assignment when its service
  principal was deleted, so moving it here was a config-only cleanup.)

## Templates (GitHub template repositories)

| Template | Repo | What you get |
|----------|------|--------------|
| `container-app` | [`KennethHeine/template-container-app`](https://github.com/KennethHeine/template-container-app) | Azure Container App, **scale-to-zero**, Log Analytics, image pull from the **estate-wide shared ACR** (`acrkscloud`) via a user-assigned managed identity holding an ABAC-conditioned `Container Registry Repository Reader` grant, secret-less **Entra Easy Auth** (default on), optional **custom domain** (managed cert), `deploy-infra` + `deploy-app` workflows that are **thin callers of the reusable workflows below**. `deploy-app` builds the image with **`az acr build`** (cloud build) and updates the app. |
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
| `.github/workflows/container-app-deploy-app.yml` | Builds images with **`az acr build`** (cloud build — no Docker on the runner) and points the Container App at the new image. `setup` → `build-app` ‖ `build-extra` (matrix, parallel) → `deploy` → `cleanup`. Input `extra_images` (JSON `[{suffix,dockerfile,context}]`) builds extra images, e.g. a sidecar/runner image, each as its own parallel job. The `cleanup` job prunes the repo's own `<repo>/` images from the shared ACR after every successful deploy (Basic SKU includes 10 GiB, and this is the only thing bounding its growth); it keeps everything referenced by active Container App revisions / ACI groups / Container Apps jobs in the RG, `latest`, the newest `image_retention_count` (default 5) tagged manifests per repository, any non-git-sha tag, multi-arch index children, and anything < 24 h old — and aborts without deleting if the in-use query fails. Cleanup failure never fails the deploy run (`continue-on-error`). |

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
the Bicep (e.g. `agent` grants its broker UAMI the specific *ACI Contributor*
role, RG-scoped, so it can manage per-session ACI — not a blanket `Contributor`,
matching the repo's own least-privilege invariant), **not** as an imperative
workflow step.

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

## Azure Container Registry — one shared registry (`acrkscloud`)

**Estate history, in order**: (1) originally one shared ACR in `rg-shared` with
a constrained RBAC-Admin delegation — abandoned for cross-repo isolation gaps;
(2) per-repo ACRs, one inside every `rg-<repo>` — the estate's default for most
of its life; (3) **2026-08-06, Kenneth's explicit cost-driven call**: back to
one shared ACR (`acrkscloud`, `rg-acr`, `acr/main.bicep`), this time with
**Entra ABAC repository permissions** (`roleAssignmentMode:
AbacRepositoryPermissions`) providing the per-repo isolation that made (1) a
bad idea — each repo's identities hold ABAC-*conditioned* roles that only
resolve for that repo's own `<repo>/` path. Migrated one repo at a time
(`inference-lab` first, isolation-tested for real — see the role-grants.json
entries below and PR history on that repo).

**The migration is COMPLETE.** All nine container-app repos are on the shared
registry, and all nine per-repo registries were deleted 2026-08-06. `acrkscloud`
is the only container registry in the subscription. The registry is **Basic**
SKU (2026-08-07): Basic and Standard have identical data-plane rate limits and
both fully support ABAC repository permissions — the only differences that reach
this estate are included storage (10 vs 100 GiB) and webhooks (2 vs 10, of which
we use zero), and Basic stays cheaper than Standard until ~158 GB stored.

**Two things this changed that are easy to miss:**

- **Under ABAC, control-plane roles grant NO data-plane access** — subscription
  Owner cannot even list repositories (`az acr repository list` returns
  `401 UNAUTHORIZED … Name:"catalog"`). `acr/main.bicep` therefore grants the
  unconditioned `Container Registry Repository Catalog Lister` to the onboarding
  SP (so decommission can enumerate) and to the operators in
  `acr/main.bicepparam` (so the registry can be audited at all). Repo identities
  never get it — they stay path-scoped.
- **A repo's images now outlive its resource group.** They used to die with
  `rg-<repo>`; now they sit in `acrkscloud` under `<repo>/`. Decommission has to
  delete them explicitly — see `decommission-repo.ps1` Step 3d.

### Shared-ACR access model (the default for every repo)

A repo is on the shared registry when it has `useSharedAcr: true` in its own
`infra/main.parameters.json` (template param, controls what the Container App's
`registries[]` points at) **and** `shared_acr: true` on its `deploy-app.yml`'s
call into `container-app-deploy-app.yml`. Both are set on every repo and in the
`container-app` template, so **new repos get this automatically** — the toggle
now exists only as a rollback hatch. Images are namespaced `<repo>/app[<suffix>]` —
the `/` boundary is what lets an ABAC condition safely
`StringStartsWithIgnoreCase '<repo>/'` without risking a substring collision
against a different repo's name.

**These grants are DERIVED, not hand-written.** They are pure boilerplate keyed
off the repo name, so `scripts/derive-acr-grants.ps1` generates them from
`repos.json` and `apply-role-grants.ps1` applies them alongside the declared
ones. **Onboarding a new container-app repo grants its registry access
automatically — there is nothing to add to `role-grants.json`.** Per repo, per
environment (prod, plus preview if `"preview": true`), it emits:

1. The repo's **CI/deploy SP** (`sp-<repo>-github`): `Container Registry
   Repository Contributor` (push+delete — not Writer, which has no delete
   DataAction and would break the `cleanup` job), ABAC-conditioned to `<repo>/`.
2. The same SP: the unconditioned control-plane pair described below.
3. Each **runtime pull identity** (default `id-<repo>`): `Container Registry
   Repository Reader`, same `<repo>/` condition.

Override the defaults with `sharedAcr` in `repos.json` (see that section) —
needed only when the runtime identity isn't named after the repo, when a repo
has several, or when a repo doesn't cloud-build.

> **Why the repo's own SP is not allowed to create these itself.** The tempting
> shortcut is to give each repo SP User Access Administrator (or a constrained
> *Role Based Access Control Administrator*) on `acrkscloud` and let the repo's
> own template Bicep declare its grants. **That silently removes the isolation
> the shared registry depends on.** Azure's constrained role-assignment
> delegation can restrict *which role* is assigned and *to which principal*, but
> there is **no attribute for the ABAC condition** on the assignment being
> created — the available Request attributes are role definition id and
> principal type/id, [and nothing else](https://learn.microsoft.com/azure/role-based-access-control/conditions-authorization-actions-attributes).
> So a repo SP permitted to assign `Container Registry Repository Contributor`
> can assign it **to itself with no condition**: unconditioned write+delete over
> every other repo's images. Plain User Access Administrator is strictly worse —
> it can also assign User Access Administrator. This estate already made this
> mistake once: era (1) above was exactly "a constrained RBAC-Admin delegation —
> abandoned for cross-repo isolation gaps". Deriving in the control plane keeps
> these where every other cross-RG grant lives, created by the onboarding SP
> that is subscription Owner anyway, so **no new privilege is introduced**.

**Plus a THIRD, unconditioned pair on the CI SP** — discovered empirically
migrating `inference-lab`, not obvious from the ABAC docs alone, and every
repo needs both of these the same way:
- `Container Registry Data Importer and Data Reader` — the ABAC data-plane
  roles grant **zero** control-plane `Microsoft.ContainerRegistry/registries/read`,
  so `az acr import` (the `prime-base-images` job's Docker Hub cache) fails
  with `"...could not be found in subscription"` — a message that looks
  nothing like a permissions error. This role is ACR's specific control-plane
  trigger for `az acr import`, plus a registry-wide PULL-only data grant to
  verify the import; it structurally cannot carry an ABAC condition (confirmed
  against the ACR built-in roles directory reference), so this is the
  permission model's own floor, not a scoping mistake.
- `Container Registry Tasks Contributor` — control-plane permission to
  trigger `az acr build` (a Quick Build / ACR Task run) at all. Also
  registry-wide, also not ABAC-conditionable.
- Additionally, `az acr build` itself needs `--source-acr-auth-id [caller]`
  passed on the command line under ABAC (`container-app-deploy-app.yml`
  handles this automatically when `shared_acr: true`) — without it the run
  gets all the way to the push and fails with `"when specifying push, at
  least one credential is required"`, because a Quick Build has zero default
  data-plane access to its own target registry once ABAC is enabled.

None of the three gaps above touch the actual isolation guarantee — they're
all either control-plane (registry existence/trigger, not repository content)
or, for Data Importer, pull-only. The property that matters (a repo's CI
cannot **write or delete** another repo's images) was isolation-tested for
real on `inference-lab`: authenticated as its own `sp-inference-lab-github`
via OIDC, a cross-repo `az acr manifest list-metadata` read got a 404 (ACR
hides even the existence of a repo you can't see, not just its content), and
a cross-repo `az acr build` push got `"denied: requested access to the
resource is denied"` on every retry.

### Per-repo ACR (rollback hatch only — nothing uses it)

Every repo's `infra/main.bicep` still carries the `useSharedAcr` toggle whose
**false** branch declares a per-repo ACR inside `rg-<repo>`. That was the
estate's default until 2026-08-06; today it is dead in practice — no registry
exists to fall back to, and a rollback would mean rebuilding images into a fresh
one.

**The ACR resource is `if (!useSharedAcr)`-guarded — keep it that way.** Until
2026-08-07 only the *role assignment* was guarded while the registry itself was
unconditional, so every `deploy-infra` run silently recreated the per-repo ACR
(the activity log caught it doing exactly that at `2026-08-06T12:37:00Z` on
`rg-agent`). It hadn't cost anything only because the deletions happened after
the last infra deploy. If you ever touch this block, the guard is the point.

**Image lifecycle**: ACR retention policies are Premium-only, so the reusable
`deploy-app` workflow's `cleanup` job prunes stale manifests after every
successful deploy instead (images are only ever *added* by deploy runs, so
cleanup-on-deploy bounds growth). It never deletes anything in use — see the
workflow table above. This is what keeps the shared registry near Basic's
10 GiB included allowance.

## Entra Easy Auth (container-app repos)

Container-app repos with `auth: true` get secret-less **Entra built-in auth**. The
auth Entra application is created **at deploy time** by the repo's own
`deploy-infra` workflow via the Microsoft Graph Bicep extension, authenticated by
the Container App's managed identity (federated credential — no client secret).

For a repo's SP to create that app, it needs the Microsoft Graph
**`Application.ReadWrite.OwnedBy`** permission. Onboarding grants it automatically
(Step 5b of `create-repo-infrastructure.ps1`), alongside **`User.Read.All`** (see
next paragraph). That works because the central onboarding SP holds
**`AppRoleAssignment.ReadWrite.All`** (granted by `setup-service-principal.ps1`),
which lets it delegate app roles to repo SPs.

So the chain is: `setup-service-principal.ps1` → onboarding SP can grant app roles
→ onboarding grants each auth repo's SP `Application.ReadWrite.OwnedBy` → that repo's
deploy creates its own Easy Auth app. The Easy Auth **token store is not enabled**
(it requires a backing blob-storage SAS URL this template doesn't provision).

**Access control (assignment required, default on).** Easy Auth is
authentication *only* — by default **any tenant member OR invited guest** can pass
the login wall, because it only checks that Entra will issue a token, not who the
user is. So the template restricts sign-in with **`appRoleAssignmentRequired`** on
the auth service principal plus an allow-list: `allowedPrincipalIds` (object ids,
for groups) and **`allowedUserEmails`** (UPNs resolved to object ids at deploy via
a `Microsoft.Graph/users existing` lookup — the human-readable way to say who gets
in). The repo SP can set `appRoleAssignmentRequired` and assign users **to its own
auth app** because it *owns* that app (a different permission from assigning roles
on other apps' SPs). Resolving emails needs Graph **`User.Read.All`**, which
Step 5b grants each auth repo SP too. Fail-safe: enforcement engages only when
`restrictAccess && the allow-list is non-empty`, so an app can't deploy into a
lock-out; the template's `main.parameters.json` ships locked to
`kenneth@kscloud.io`, so **new apps are private by default** (set
`restrictAccess:false` or empty the list to make one open). Assignments are
created even before the toggle engages, so turning it on later is a safe second
deploy, never a single risky one.

## Per-branch preview environments (opt-in)

A container-app repo with `"preview": true` in `repos.json` gets an **isolated
sandbox** so non-`main` branches can deploy without any path to prod. Today only
`agent` opts in (claude-runner did too, until it was decommissioned 2026-08-05);
the OIDC/routing mechanism is generic.

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

**The caller opts in** (`agent`'s `deploy-infra.yml`/`deploy-app.yml`):
`with: { preview: true }`, a `test/**` push trigger, and the prod-only `verify`
job is skipped on non-`main`. So **push a `test/**` branch → preview; `main` → prod.**
deploy-app concurrency is keyed per `github.ref` so prod and preview deploys
never cancel each other.

**Base-split (a trap this pattern hit while previews had their own registry).**
claude-runner's slim Dockerfiles `FROM` its own base images, so its fresh
(empty) preview ACR couldn't resolve them and `prime-base-images` couldn't
import internal `*-base` tags from Docker Hub — its `build-base-images.yml` grew
a dedicated **`preview-seed`** job to build the bases into the preview ACR too.
Since consolidation this specific gap is mostly closed: preview builds into the
same `acrkscloud` as prod (under its own `<repo>-preview/` prefix), so shared
root-level base-image caches are already there. Preview still cannot read
prod's `<repo>/` path, so a base image published only under `<repo>/` remains
unreachable from preview — if a preview-opted repo's slim Dockerfiles `FROM`
its own internal base images, check this first.

**Cost.** Compute scales to zero and the preview registry is gone — previews now
share `acrkscloud`, so a preview environment's standing cost is **effectively
zero** (just its slice of image storage). Infra is kept standing (no idle
teardown) for fast feedback — a test iteration runs only `deploy-app` (~1-2 min),
not `deploy-infra`. The per-deploy `cleanup` job prunes the `<repo>-preview/`
images like prod's. `decommission-repo.ps1` tears the whole preview footprint
down with the repo (Step 3c), including its shared-registry images and grants
(Step 3d). Full design + history: `PLAN-preview-env.md`.

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
into `confirm`. It removes the repo's entries from **`repos.json`,
`role-grants.json` and `graph-grants.json`** (one atomic commit — the grant
appliers are additive and would otherwise re-grant on a same-name re-onboard),
and deletes `rg-<repo>`, the SP, **any Entra apps the SP owns (e.g. the Easy
Auth app)**, **the preview footprint if any (`sp-<repo>-preview-github` +
`rg-<repo>-preview`, Step 3c)**, **its images + ABAC role assignments on the
shared registry `acrkscloud` (Step 3d — these no longer die with the RG)**, and
— per the `github_repo` input — **keeps**, **archives** (read-only), or
**deletes** the GitHub repo.

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

## GitHub App for coding-agent sessions (as code)

Autonomous coding-agent sessions authenticate to GitHub with a **GitHub App**
(short-lived installation tokens; safer than a personal account). GitHub does
not allow creating apps via plain REST/Bicep, so this repo codifies the maximum
GitHub supports — the **app manifest flow**. The app is still literally named
`claude-runner-agent` — created for that platform, and kept installed/reused by
its successor `agent` rather than recreated, since re-running the manifest flow
mints a brand-new app id (see `create-github-app.ps1`'s own idempotency note).

| File | Holds |
|------|-------|
| `github-app/manifest.json` | The app definition: name `claude-runner-agent`, no webhook, repository permissions Contents/Actions/Workflows/PRs/Issues **RW** + Metadata R |
| `scripts/create-github-app.ps1` | Drives the manifest flow end-to-end: browser confirm (once) → exchanges the code for app id + private key → uploads the PEM **directly into the target repo's Key Vault** (`github-app-private-key`, defaults to `agent`'s) → prints the install link and the `githubAppId` value to set in that repo's `infra/main.parameters.json` |

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
| `onboard-repos.yml` | push to `repos.json`, `role-grants.json` or `graph-grants.json` on main, manual | Provision/refresh all repos; apply estate-wide RBAC + Graph grants |
| `add-repo.yml` | manual (inputs) | Add an entry to repos.json → triggers onboarding |
| `decommission-repo.yml` | manual (inputs + confirm) | Full teardown of one repo (incl. its images + grants on the shared ACR, and its entries in the grant configs) |
| `acr-deploy.yml` | push to `acr/**` on main, manual | Deploy the estate-wide shared registry `acrkscloud` (creates `rg-acr`) from `acr/main.bicepparam` |
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
- Keep everything **idempotent** and **scoped** (per-repo resources live in
  `rg-<repo>`; estate-wide singletons live in their own RG — the DNS zone in
  `rg-dns`, the shared container registry in `rg-acr`).
- **No stored credentials** — OIDC federated identity for CI, managed identities
  for runtime.
- PowerShell scripts target **pwsh 7+**; validate edits with
  `[Parser]::ParseFile(...)` and Bicep with `az bicep build`.
- After changing onboarding logic, prefer validating against a throwaway repo via
  the Add/Decommission workflows rather than an existing one.
- **Base images through ACR**: container-app Dockerfiles should declare
  `ARG ACR_LOGIN_SERVER=docker.io` and `FROM ${ACR_LOGIN_SERVER}/<path>:<tag>`
  — the reusable deploy-app workflow injects the shared ACR's login server and
  lazily imports/refreshes the base image (Docker Hub anonymous pulls 429
  under ACR's shared egress IP; anonymous cache *rules* are blocked by Azure).
