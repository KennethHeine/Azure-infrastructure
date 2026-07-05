# Apply estate-wide Microsoft Graph app-role (application permission) grants from graph-grants.json
#
# Application-permission (app-role) assignments to user-assigned managed identities.
# These are Entra DIRECTORY grants on a resource service principal (e.g. Microsoft
# Graph) — NOT Azure RBAC (that is role-grants.json). Only the onboarding SP can
# create them: it holds Microsoft Graph AppRoleAssignment.ReadWrite.All; a repo's
# own SP does not. Declaring them here keeps every app-only permission under code
# review, applied by the onboarding SP alongside the RBAC grants.
#
# A managed identity's principalId IS its service principal object id, so each
# assignment is POSTed to /servicePrincipals/{principalId}/appRoleAssignments with
# body { principalId, resourceId (the resource SP), appRoleId }.
#
# Idempotent — existing assignments are skipped. An identity that does not exist
# yet (its repo's infra deploy hasn't run) is a warning, not a failure; the grant
# is applied on the next onboarding run.
#
# Usage:
#   .\scripts\apply-graph-grants.ps1                          # use ./graph-grants.json
#   .\scripts\apply-graph-grants.ps1 -ConfigFile other.json   # explicit config path

[CmdletBinding()]
param(
    [string]$ConfigFile
)

$ErrorActionPreference = "Stop"

# ─── Resolve config file path ────────────────────────────────────────
if (-not $ConfigFile) {
    $repoRoot = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { Get-Location }
    $ConfigFile = Join-Path $repoRoot "graph-grants.json"
}

if (-not (Test-Path $ConfigFile)) {
    Write-Host "Error: Config file not found: $ConfigFile" -ForegroundColor Red
    exit 1
}

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Apply Estate-wide Graph App-Role Grants" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Config file: $ConfigFile"

$grants = (Get-Content $ConfigFile -Raw | ConvertFrom-Json).grants
if (-not $grants -or $grants.Count -eq 0) {
    Write-Host "No grants defined in config file. Nothing to do." -ForegroundColor Yellow
    exit 0
}

Write-Host "Grants:      $($grants.Count) identity/-ies to ensure" -ForegroundColor Cyan
Write-Host ""

# Microsoft Graph well-known appId — the default resource. App role ids are
# constant across tenants (see the resource API's permission reference).
$graphAppId = "00000003-0000-0000-c000-000000000000"

# Resolve each resource SP object id at most once.
$resourceSpIdCache = @{}
function Get-ResourceSpId([string]$appId) {
    if ($resourceSpIdCache.ContainsKey($appId)) { return $resourceSpIdCache[$appId] }
    $spId = az ad sp show --id $appId --query id -o tsv --only-show-errors 2>$null
    $resourceSpIdCache[$appId] = $spId
    return $spId
}

$failed = $false

foreach ($grant in $grants) {
    $name = $grant.identityName
    $rg = $grant.identityResourceGroup
    Write-Host "Identity $name (in $rg):"

    # A managed identity's principalId is its service principal object id. Not
    # existing yet is expected when the owning repo's infra deploy hasn't run.
    $principalId = az identity show -g $rg -n $name --query principalId -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $principalId) {
        Write-Host "::warning::Identity $name not found in $rg — its repo's infra deploy hasn't run yet. Grant skipped; re-run onboarding afterwards."
        continue
    }

    $resourceAppId = if ($grant.resourceAppId) { $grant.resourceAppId } else { $graphAppId }
    $resourceSpId = Get-ResourceSpId $resourceAppId
    if (-not $resourceSpId) {
        Write-Host "::error::Could not resolve resource service principal for appId $resourceAppId — skipping $name."
        $failed = $true
        continue
    }

    # Existing app-role assignments on this identity's SP — one GET, checked per role.
    $existingJson = az rest --method GET `
        --url "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" `
        --query "value[].appRoleId" -o json --only-show-errors 2>$null
    $existingRoleIds = if ($existingJson) { @($existingJson | ConvertFrom-Json) } else { @() }

    foreach ($role in $grant.appRoles) {
        $roleName = $role.name
        $roleId = $role.appRoleId
        if ($existingRoleIds -contains $roleId) {
            Write-Host "  '$roleName' — already granted" -ForegroundColor DarkGray
            continue
        }
        Write-Host "  '$roleName' — granting…" -ForegroundColor Yellow
        $body = "{`"principalId`":`"$principalId`",`"resourceId`":`"$resourceSpId`",`"appRoleId`":`"$roleId`"}"
        az rest --method POST `
            --url "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" `
            --headers "Content-Type=application/json" `
            --body $body --only-show-errors 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "::error::Failed to grant '$roleName' to $name"
            $failed = $true
            continue
        }
        Write-Host "  '$roleName' — granted" -ForegroundColor Green
    }
}

Write-Host ""
if ($failed) {
    Write-Host "One or more Graph app-role grants failed." -ForegroundColor Red
    exit 1
}
Write-Host "All Graph app-role grants ensured." -ForegroundColor Green
exit 0
