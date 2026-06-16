# Apply estate-wide RBAC grants from role-grants.json
#
# Repo-scoped RBAC lives in each repo's own Bicep (its SP is Owner of its RG).
# Grants that EXCEED a repo's scope cannot be created by the repo's own SP, so
# they are declared here and applied by the onboarding SP (subscription Owner).
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

$grants = (Get-Content $ConfigFile -Raw | ConvertFrom-Json).grants
if (-not $grants -or $grants.Count -eq 0) {
    Write-Host "No grants defined in config file. Nothing to do." -ForegroundColor Yellow
    exit 0
}

$subscriptionId = az account show --query id -o tsv
if ($LASTEXITCODE -ne 0 -or -not $subscriptionId) {
    Write-Host "::error::Could not resolve the current subscription (az login?)"
    exit 1
}

Write-Host "Grants:      $($grants.Count) to ensure" -ForegroundColor Cyan
Write-Host ""

$failed = $false

foreach ($grant in $grants) {
    $name = $grant.identityName
    $rg = $grant.identityResourceGroup
    Write-Host "Identity $name (in $rg):"

    # Resolve the identity's principal id. Not existing yet is expected when
    # the owning repo's infra deploy hasn't run — warn and continue.
    $principalId = az identity show -g $rg -n $name --query principalId -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $principalId) {
        Write-Host "::warning::Identity $name not found in $rg — its repo's infra deploy hasn't run yet. Grant skipped; re-run onboarding afterwards."
        continue
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
        Write-Host "  '$role' at $($grant.scope) — assigning…" -ForegroundColor Yellow
        az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal `
            --role $role --scope $scope --only-show-errors | Out-Null
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
