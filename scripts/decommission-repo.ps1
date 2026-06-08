# Decommission a repository's Azure + GitHub footprint.
#
# Tears down everything the onboarding created for a single repo:
#   1. Deletes the repo's image repository from the shared ACR
#   2. Removes the repo SP's role assignments on the shared ACR (AcrPush + the
#      constrained RBAC-admin delegation) — these are NOT inside rg-<repo>, so
#      deleting the resource group doesn't remove them
#   3. Deletes the app registration sp-<repo>-github (removes the SP + its
#      federated credentials + its rg-scoped role assignments)
#   4. Deletes the resource group rg-<repo> (Container App, env, Log Analytics,
#      managed identity, auth Entra app, etc.)
#   5. (Optional) Deletes the GitHub repository
#
# Removing the entry from repos.json is handled by the decommission workflow,
# not this script.
#
# Idempotent and best-effort: missing pieces are logged and skipped, so re-running
# after a partial teardown completes cleanly.
#
# Usage:
#   .\scripts\decommission-repo.ps1 -GitHubRepo "my-app"
#   .\scripts\decommission-repo.ps1 -GitHubRepo "my-app" -DeleteGitHubRepo

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GitHubRepo,

    [string]$GitHubOrg = "KennethHeine",

    [string]$SharedResourceGroup = "rg-shared",

    # Also delete the GitHub repository (needs AUTOMATION_GITHUB_TOKEN with
    # delete_repo scope). Off by default — destructive and irreversible.
    [switch]$DeleteGitHubRepo
)

$ErrorActionPreference = "Stop"

$ResourceGroupName    = "rg-$GitHubRepo"
$ServicePrincipalName = "sp-$GitHubRepo-github"
$repoFullName         = "$GitHubOrg/$GitHubRepo"
$imageRepo            = $GitHubRepo.ToLower()

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Decommission Repository Infrastructure" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "GitHub Repo:       $repoFullName"
Write-Host "Resource Group:    $ResourceGroupName"
Write-Host "Service Principal: $ServicePrincipalName"
Write-Host "Delete GitHub repo: $DeleteGitHubRepo"
Write-Host ""

# ─── Prerequisites ───────────────────────────────────────────────────
try { $null = Get-Command az -ErrorAction Stop } catch {
    Write-Host "Error: Azure CLI is not installed." -ForegroundColor Red; exit 1
}

az account show --output none --only-show-errors 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Not logged in to Azure. Run 'az login' first." -ForegroundColor Red; exit 1
}
$global:LASTEXITCODE = 0

# Resolve the SP appId (may already be gone on a re-run).
$appId = az ad app list --display-name $ServicePrincipalName --query "[0].appId" --output tsv --only-show-errors
$global:LASTEXITCODE = 0

# ─── Step 1: Delete the image from the shared ACR ────────────────────
Write-Host "Step 1: Removing image repository '$imageRepo' from shared ACR..." -ForegroundColor Cyan
$acrName = az acr list --resource-group $SharedResourceGroup --query "[0].name" --output tsv --only-show-errors
$global:LASTEXITCODE = 0
if ($acrName) {
    az acr repository delete --name $acrName --repository $imageRepo --yes --only-show-errors 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Deleted image repository '$imageRepo' from '$acrName'" -ForegroundColor Green
    } else {
        Write-Host "  No image repository '$imageRepo' in '$acrName' (nothing to delete)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  No shared ACR found in '$SharedResourceGroup' — skipping" -ForegroundColor Yellow
}
$global:LASTEXITCODE = 0
Write-Host ""

# ─── Step 2: Remove the SP's role assignments on the shared ACR ──────
Write-Host "Step 2: Removing shared-ACR role assignments for the service principal..." -ForegroundColor Cyan
if ($appId) {
    $acrId = az acr show --name $acrName --query "id" --output tsv --only-show-errors 2>&1
    if ($acrName -and $LASTEXITCODE -eq 0 -and $acrId) {
        az role assignment delete --assignee $appId --scope $acrId --only-show-errors 2>&1 | Out-Null
        Write-Host "  Removed ACR role assignments for $appId" -ForegroundColor Green
    } else {
        Write-Host "  No ACR found — skipping ACR role-assignment cleanup" -ForegroundColor Yellow
    }
} else {
    Write-Host "  App registration not found — nothing to clean up" -ForegroundColor Yellow
}
$global:LASTEXITCODE = 0
Write-Host ""

# ─── Step 3: Delete the app registration (removes SP + fed creds) ────
Write-Host "Step 3: Deleting app registration '$ServicePrincipalName'..." -ForegroundColor Cyan
if ($appId) {
    az ad app delete --id $appId --only-show-errors 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Deleted app registration (appId: $appId)" -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Failed to delete app registration $appId" -ForegroundColor Yellow
    }
} else {
    Write-Host "  Already gone — skipping" -ForegroundColor Yellow
}
$global:LASTEXITCODE = 0
Write-Host ""

# ─── Step 4: Delete the resource group ───────────────────────────────
Write-Host "Step 4: Deleting resource group '$ResourceGroupName'..." -ForegroundColor Cyan
$rgExists = az group exists --name $ResourceGroupName --only-show-errors
if ($rgExists -eq "true") {
    az group delete --name $ResourceGroupName --yes --only-show-errors 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Deleted resource group '$ResourceGroupName'" -ForegroundColor Green
    } else {
        Write-Host "Error: Failed to delete resource group '$ResourceGroupName'" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  Resource group '$ResourceGroupName' does not exist — skipping" -ForegroundColor Yellow
}
$global:LASTEXITCODE = 0
Write-Host ""

# ─── Step 5: (Optional) Delete the GitHub repository ─────────────────
if ($DeleteGitHubRepo) {
    Write-Host "Step 5: Deleting GitHub repository '$repoFullName'..." -ForegroundColor Cyan
    $ghToken = $env:AUTOMATION_GITHUB_TOKEN
    if (-not $ghToken) {
        Write-Host "  WARNING: AUTOMATION_GITHUB_TOKEN not set — cannot delete GitHub repo" -ForegroundColor Yellow
    } else {
        $env:GH_TOKEN = $ghToken
        gh repo delete $repoFullName --yes 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Deleted GitHub repository '$repoFullName'" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: Failed to delete '$repoFullName' (token may lack the 'delete_repo' scope)" -ForegroundColor Yellow
        }
        $global:LASTEXITCODE = 0
    }
    Write-Host ""
}

# ─── Summary ─────────────────────────────────────────────────────────
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Decommission Complete" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Removed: rg-$GitHubRepo, $ServicePrincipalName, shared-ACR grants + image" -ForegroundColor Green
if (-not $DeleteGitHubRepo) {
    Write-Host "The GitHub repository '$repoFullName' was kept (re-run with -DeleteGitHubRepo to remove it)." -ForegroundColor Cyan
}
Write-Host "Remember to remove '$GitHubRepo' from repos.json (the workflow does this)." -ForegroundColor Cyan
Write-Host ""
