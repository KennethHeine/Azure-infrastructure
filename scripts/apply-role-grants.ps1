# Apply estate-wide RBAC grants — derived (shared ACR) + declared (role-grants.json)
#
# Repo-scoped RBAC lives in each repo's own Bicep (its SP is Owner of its RG).
# Grants that EXCEED a repo's scope cannot be created by the repo's own SP, so
# they are applied here by the onboarding SP (subscription Owner). Two sources:
#
#   * DERIVED  — the shared-ACR grants every container-app repo needs, generated
#                from repos.json by scripts/derive-acr-grants.ps1. Pure
#                boilerplate keyed off the repo name, so a newly onboarded repo
#                gets registry access automatically. That script's header
#                explains why the repo SP is not given RBAC-admin rights on the
#                registry to do this for itself.
#   * DECLARED — role-grants.json, for everything genuinely bespoke.
#
# This keeps every cross-RG permission under code control and review. Two scopes:
#   * subscription — e.g. subscription Reader for the coder-session identity.
#   * resource     — a single resource OUTSIDE the identity's repo RG, named by
#                    scopeResourceId (e.g. the claude-runner-test broker needing
#                    SSH + Run Command on the Azure Arc machine in rg-homelab).
#
# Idempotent — existing assignments are skipped. An identity that does not
# exist yet (its repo's infra deploy hasn't run) is a warning, not a failure;
# the grant is applied on the next onboarding run.
#
# A grant may carry an ABAC 'condition' + 'conditionVersion' (e.g. to scope an
# ACR "Container Registry Repository Writer" role to one repository path on a
# shared, ABAC-enabled registry). CAVEAT: the existing-assignment check below
# matches on (assignee, role, scope) only, not condition text — so editing a
# condition on an already-applied grant will not re-apply it; delete the stale
# assignment first (az role assignment delete) to force recreation.
#
# Usage:
#   .\scripts\apply-role-grants.ps1                          # use ./role-grants.json
#   .\scripts\apply-role-grants.ps1 -ConfigFile other.json   # explicit config path

[CmdletBinding()]
param(
    [string]$ConfigFile
)

$ErrorActionPreference = "Stop"

# ─── Resolve config file path ────────────────────────────────────────
if (-not $ConfigFile) {
    $repoRoot = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { Get-Location }
    $ConfigFile = Join-Path $repoRoot "role-grants.json"
}

if (-not (Test-Path $ConfigFile)) {
    Write-Host "Error: Config file not found: $ConfigFile" -ForegroundColor Red
    exit 1
}

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Apply Estate-wide RBAC Grants" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Config file: $ConfigFile"

$declaredGrants = @((Get-Content $ConfigFile -Raw | ConvertFrom-Json).grants)

$subscriptionId = az account show --query id -o tsv
if ($LASTEXITCODE -ne 0 -or -not $subscriptionId) {
    Write-Host "::error::Could not resolve the current subscription (az login?)"
    exit 1
}

# ─── Derived shared-ACR grants ───────────────────────────────────────
# Every container-app repo needs the same boilerplate grants on the shared
# registry, mechanically derived from its name. They are GENERATED from
# repos.json rather than hand-written here, so onboarding a new repo grants its
# registry access automatically instead of failing its first deploy-app on a
# forgotten config entry. See scripts/derive-acr-grants.ps1 — including why the
# repo's own SP is deliberately NOT allowed to create these itself.
$derivedGrants = @()
$deriveScript = Join-Path $PSScriptRoot "derive-acr-grants.ps1"
if (Test-Path $deriveScript) {
    $reposConfig = Join-Path (Split-Path $PSScriptRoot -Parent) "repos.json"
    if (Test-Path $reposConfig) {
        $derivedGrants = @(& $deriveScript -ConfigFile $reposConfig -SubscriptionId $subscriptionId)
        Write-Host "Derived:     $($derivedGrants.Count) shared-ACR grant(s) from repos.json" -ForegroundColor Cyan
    }
}

$grants = @($derivedGrants) + @($declaredGrants)
if ($grants.Count -eq 0) {
    Write-Host "No grants defined. Nothing to do." -ForegroundColor Yellow
    exit 0
}

Write-Host "Declared:    $($declaredGrants.Count) grant(s) in $(Split-Path $ConfigFile -Leaf)" -ForegroundColor Cyan
Write-Host "Grants:      $($grants.Count) to ensure" -ForegroundColor Cyan
Write-Host ""

$failed = $false

foreach ($grant in $grants) {
    $name = $grant.identityName
    $isServicePrincipal = $grant.identityType -eq "servicePrincipal"

    # Resolve the principal id. Two identity kinds:
    #  - managedIdentity (default): a Microsoft.ManagedIdentity resource, via az identity show.
    #  - servicePrincipal: an Entra SP NOT backed by a managed identity (e.g. a repo's own
    #    sp-<repo>-github OIDC deploy identity, created via az ad app/sp during onboarding),
    #    via az ad sp list --display-name. Not existing yet is expected either way when the
    #    owning repo's infra/onboarding hasn't run — warn and continue, not fail.
    if ($isServicePrincipal) {
        Write-Host "Identity $name (service principal):"
        $principalId = az ad sp list --display-name $name --query '[0].id' -o tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $principalId) {
            Write-Host "::warning::Service principal $name not found — its repo's onboarding (which creates sp-<repo>-github) hasn't run yet. Grant skipped; re-run onboarding afterwards."
            continue
        }
    }
    else {
        $rg = $grant.identityResourceGroup
        Write-Host "Identity $name (in $rg):"
        $principalId = az identity show -g $rg -n $name --query principalId -o tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $principalId) {
            Write-Host "::warning::Identity $name not found in $rg — its repo's infra deploy hasn't run yet. Grant skipped; re-run onboarding afterwards."
            continue
        }
    }

    # Resolve the assignment scope. 'subscription' = the whole subscription;
    # 'resource' = the literal scopeResourceId (a cross-RG resource the repo SP
    # cannot grant on itself). Schema requires scopeResourceId when resource.
    if ($grant.scope -eq "resource") {
        if (-not $grant.scopeResourceId) {
            Write-Host "::error::Grant for $name has scope 'resource' but no scopeResourceId — skipping."
            $failed = $true
            continue
        }
        $scope = $grant.scopeResourceId
    }
    else {
        $scope = "/subscriptions/$subscriptionId"
    }

    foreach ($role in $grant.roles) {
        $existing = az role assignment list --assignee $principalId --role $role --scope $scope --query '[0].id' -o tsv 2>$null
        if ($existing) {
            Write-Host "  '$role' at $($grant.scope) — already assigned" -ForegroundColor DarkGray
            continue
        }
        $conditionNote = if ($grant.condition) { " (ABAC-conditioned)" } else { "" }
        Write-Host "  '$role' at $($grant.scope)$conditionNote — assigning…" -ForegroundColor Yellow
        $createArgs = @(
            '--assignee-object-id', $principalId,
            '--assignee-principal-type', 'ServicePrincipal',
            '--role', $role,
            '--scope', $scope,
            '--only-show-errors'
        )
        if ($grant.condition) {
            $createArgs += @('--condition', $grant.condition, '--condition-version', $grant.conditionVersion)
        }
        az role assignment create @createArgs | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "::error::Failed to assign '$role' to $name"
            $failed = $true
            continue
        }
        Write-Host "  '$role' at $($grant.scope) — assigned" -ForegroundColor Green
    }
}

Write-Host ""
if ($failed) {
    Write-Host "One or more grants failed." -ForegroundColor Red
    exit 1
}
Write-Host "All grants ensured." -ForegroundColor Green
exit 0
