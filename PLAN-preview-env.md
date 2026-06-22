# Plan: per-branch preview environments (claude-runner first, opt-in)

## Context / why
Today only `main` + PRs can OIDC into Azure (the repo SP's federated credentials
are `ref:refs/heads/main` and `pull_request`). So a `workflow_dispatch` from a
feature branch fails `azure/login` — you can't validate a deploy/workflow change
on a branch before merging (hit this while testing the GHA build-cache change).

Fix (Kenneth's idea, better than widening prod trust): branches deploy to an
**isolated preview RG**, never to prod. The safety comes from a **separate
identity** — an OIDC token doesn't tell Azure which branch it's from, so a branch
must assume a different SP that is Owner of *only* the preview RG.

Scope: **claude-runner only, opt-in** (`preview: true` in repos.json). Prove the
loop, then decide on estate-wide rollout. Keep cost to one extra app/ACR.

## Design
- **Preview SP** `sp-<repo>-preview-github`: federated to `refs/heads/*` (any
  branch, via a flexible FIC `claimsMatchingExpression`); **Owner of
  `rg-<repo>-preview` only** — cannot touch prod.
- **Prod SP unchanged**: `main` + PRs, Owner of `rg-<repo>`.
- **Deploy routes by ref**: `main` → prod SP + `rg-<repo>`; any other branch →
  preview SP + `rg-<repo>-preview`.
- Preview RG starts empty; the first branch `deploy-infra` populates it (its own
  ACR + container app), so onboarding stays cheap (empty RG + a free SP).

## Increments
### 1 — Onboarding foundation (this PR)
- `repos.schema.json`: add optional `preview` boolean.
- `repos.json`: `claude-runner` → `"preview": true`.
- `scripts/process-repos.ps1`: read `.preview` (default false), pass `-Preview`.
- `scripts/create-repo-infrastructure.ps1`: add `[bool]$Preview`; when set,
  create `rg-<repo>-preview`, `sp-<repo>-preview-github`, a wildcard FIC
  (`refs/heads/*`), Owner on the preview RG, and set repo **secret**
  `AZURE_CLIENT_ID_PREVIEW` + **var** `RESOURCE_GROUP_PREVIEW`. Self-contained,
  idempotent, mirrors the existing SP/role/secret patterns.
- Validate: merge → run **Onboard Repositories** → confirm the SP/RG/FIC/secret
  exist (workflow log + `az ad app federated-credential list`).

### 2 — Branch→preview routing
- Reusable `container-app-deploy-infra.yml` + `container-app-deploy-app.yml`:
  add inputs `preview_client_id` / `preview_resource_group` (or read the
  branch + the `*_PREVIEW` secret/var); when `github.ref != main`, log in with
  the preview SP and target the preview RG. Default/`main` path byte-identical.
- claude-runner deploy callers opt in (pass the preview secret/var).
- Validate: push a `test/*` branch → app deploys to `rg-claude-runner-preview`;
  confirm prod revision untouched.

### 3 — Teardown / cost control
- A teardown workflow (or sweeper) that empties `rg-<repo>-preview` when a branch
  is deleted / preview is stale; `decommission-repo.ps1` also removes the preview
  SP + RG.

## Notes / risks
- Flexible FIC (`claimsMatchingExpression`) needs a recent `az` (onboarding runs
  on ubuntu-latest — fine); validate the create call in the onboarding log.
- The preview SP matching `refs/heads/*` includes `main`, but it's Owner of only
  the preview RG, so that's harmless; routing still sends `main` to the prod SP.
- I'm subscription **Reader** — the SP/RG are created by **Onboard Repositories**
  (runs as the onboarding SP), not by me directly.
