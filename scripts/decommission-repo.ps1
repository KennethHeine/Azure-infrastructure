# Decommission a repository's Azure + GitHub footprint.
#
# Tears down everything the onboarding created for a single repo:
#   1. Deletes the app registration sp-<repo>-github (removes the SP + its
#      federated credentials + its rg-scoped role assignments)
#   2. Deletes the resource group rg-<repo> (Container App, env, Log Analytics,
#      the repo's own ACR + images, managed identity, etc.)
#   3. (Optional) Archives (read-only) or deletes the GitHub repository
#
# The repo's container registry now lives inside rg-<repo>, so it (and its
# images) are removed when the resource group is deleted — no shared-registry
# cleanup is needed.
#
# Removing the entry from repos.json is handled by the decommission workflow,
# not this script.
#
# Idempotent and best-effort: missing pieces are logged and skipped, so re-running
# after a partial teardown completes cleanly.
#
# Usage:
#   .\scripts\decommission-repo.ps1 -GitHubRepo "my-app"
#   .\scripts\decommission-repo.ps1 -GitHubRepo "my-app" -GitHubRepoAction archive
#   .\scripts\decommission-repo.ps1 -GitHubRepo "my-app" -GitHubRepoAction delete

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GitHubRepo,

    [string]$GitHubOrg = "KennethHeine",

    # What to do with the GitHub repository after tearing down Azure:
    #   keep    -> leave it untouched (default)
    #   archive -> make it read-only (preserves the code; needs 'repo' scope)
    #   delete  -> delete it permanently (needs 'delete_repo' scope)
    [ValidateSet("keep", "archive", "delete")]
    [string]$GitHubRepoAction = "keep"
)

$ErrorActionPreference = "Stop"

$ResourceGroupName    = "rg-$GitHubRepo"
$ServicePrincipalName = "sp-$GitHubRepo-github"
$repoFullName         = "$GitHubOrg/$GitHubRepo"

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Decommission Repository Infrastructure" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "GitHub Repo:       $repoFullName"
Write-Host "Resource Group:    $ResourceGroupName"
Write-Host "Service Principal: $ServicePrincipalName"
Write-Host "GitHub repo action: $GitHubRepoAction"
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

# ─── Step 1: Delete Entra apps owned by the SP (e.g. Easy Auth app) ──
# Container-app repos with auth create their own Entra "Easy Auth" application
# at deploy time; the repo SP becomes its owner. That app is a directory object
# (not inside rg-<repo>), so deleting the resource group won't remove it. Delete
# every application this SP owns before deleting the SP itself.
Write-Host "Step 1: Deleting Entra apps owned by the service principal..." -ForegroundColor Cyan
if ($appId) {
    $spObjId = az ad sp list --display-name $ServicePrincipalName --query "[0].id" --output tsv --only-show-errors
    if ($spObjId) {
        $ownedJson = az rest --method GET `
            --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spObjId/ownedObjects" `
            --output json --only-show-errors 2>&1
        if ($LASTEXITCODE -eq 0 -and $ownedJson) {
            $owned = $ownedJson | ConvertFrom-Json
            $apps = @($owned.value | Where-Object {
                $_.'@odata.type' -eq '#microsoft.graph.application' -and $_.appId -ne $appId
            })
            if ($apps.Count -eq 0) {
                Write-Host "  No owned Entra apps to delete" -ForegroundColor Yellow
            }
            foreach ($app in $apps) {
                az ad app delete --id $app.appId --only-show-errors 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  Deleted Entra app '$($app.displayName)' ($($app.appId))" -ForegroundColor Green
                } else {
                    Write-Host "  WARNING: Failed to delete Entra app $($app.appId)" -ForegroundColor Yellow
                }
                # `az ad app delete` only SOFT-deletes (30-day retention). The Easy
                # Auth app's uniqueName is uniqueString(subscription, rg.id)-derived —
                # identical for a same-named RG recreated later — and a soft-deleted
                # app keeps that uniqueName reserved, so a re-onboard's
                # Microsoft.Graph Bicep deploy can't recreate the app: it fails with
                # the dependent SP/federatedCredential erroring "appId doesn't exist" /
                # "Resource ... does not exist". Permanently delete it so the name is
                # freed. (Needs Graph Application.ReadWrite.All — the onboarding SP has
                # it.)
                az rest --method DELETE `
                    --url "https://graph.microsoft.com/v1.0/directory/deletedItems/$($app.id)" `
                    --only-show-errors 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "    Purged '$($app.displayName)' from deleted items (uniqueName freed)" -ForegroundColor Green
                } else {
                    Write-Host "    WARNING: Could not purge '$($app.displayName)' from deleted items — a same-name re-onboard may need a manual purge" -ForegroundColor Yellow
                }
                $global:LASTEXITCODE = 0
            }
        } else {
            Write-Host "  Could not list owned objects — skipping" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  SP object id not found — skipping" -ForegroundColor Yellow
    }
} else {
    Write-Host "  App registration not found — skipping" -ForegroundColor Yellow
}
$global:LASTEXITCODE = 0
Write-Host ""

# ─── Step 2: Delete the app registration (removes SP + fed creds) ────
Write-Host "Step 2: Deleting app registration '$ServicePrincipalName'..." -ForegroundColor Cyan
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

# ─── Step 3: Delete the resource group (incl. the repo's own ACR) ────
Write-Host "Step 3: Deleting resource group '$ResourceGroupName'..." -ForegroundColor Cyan
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

# ─── Step 3b: Purge soft-deleted Key Vaults that belonged to this RG ─
# Deleting the resource group only SOFT-deletes its Key Vault(s); the name
# lingers in the subscription's soft-delete retention (default 90 days). The
# container-app template derives the vault name from
# uniqueString(resourceGroup().id) — identical for a same-named RG recreated
# later — so a lingering soft-deleted vault blocks re-onboarding with
# "A vault with the same name already exists in deleted state" (the deploy fails
# at the Key Vault resource). Purge the vaults that belonged to this RG so the
# name is free to recreate. Purge is a subscription-scope action; the onboarding
# SP is subscription Owner, so it can. Match on the deleted vault's original
# vaultId (PowerShell -like is case-insensitive) rather than a name prefix, so
# we only ever purge vaults from THIS repo's RG.
Write-Host "Step 3b: Purging soft-deleted Key Vaults from '$ResourceGroupName'..." -ForegroundColor Cyan
$allDeleted = az keyvault list-deleted -o json --only-show-errors 2>$null | ConvertFrom-Json
$deletedVaults = @($allDeleted | Where-Object { $_.properties.vaultId -like "*/resourceGroups/$ResourceGroupName/*" })
if ($deletedVaults.Count -eq 0) {
    Write-Host "  No soft-deleted Key Vaults to purge for this RG" -ForegroundColor Yellow
} else {
    foreach ($v in $deletedVaults) {
        Write-Host "  Purging soft-deleted vault '$($v.name)' ($($v.properties.location))..." -NoNewline
        az keyvault purge --name $v.name --location $v.properties.location --only-show-errors 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host " purged" -ForegroundColor Green
        } else {
            # Don't fail the teardown: a purge-protected vault can't be purged
            # until retention expires, and the RG/SP are already gone. Warn so a
            # later same-name re-onboard knows it must purge (or rename) first.
            Write-Host " WARNING: purge failed (purge protection, or already purged)" -ForegroundColor Yellow
        }
        $global:LASTEXITCODE = 0
    }
}
Write-Host ""

# ─── Step 4: Archive or delete the GitHub repository ─────────────────
if ($GitHubRepoAction -ne "keep") {
    Write-Host "Step 4: $($GitHubRepoAction)ing GitHub repository '$repoFullName'..." -ForegroundColor Cyan
    $ghToken = $env:AUTOMATION_GITHUB_TOKEN
    if (-not $ghToken) {
        Write-Host "  WARNING: AUTOMATION_GITHUB_TOKEN not set — cannot $GitHubRepoAction GitHub repo" -ForegroundColor Yellow
    } else {
        $env:GH_TOKEN = $ghToken
        if ($GitHubRepoAction -eq "archive") {
            # Make the repo read-only (preserves the code). Needs 'repo' scope.
            gh api --method PATCH "repos/$repoFullName" -F archived=true --silent 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Archived GitHub repository '$repoFullName' (now read-only)" -ForegroundColor Green
            } else {
                Write-Host "  WARNING: Failed to archive '$repoFullName'" -ForegroundColor Yellow
            }
        } else {
            # delete — permanent. Needs 'delete_repo' scope.
            gh repo delete $repoFullName --yes 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Deleted GitHub repository '$repoFullName'" -ForegroundColor Green
            } else {
                Write-Host "  WARNING: Failed to delete '$repoFullName' (token may lack the 'delete_repo' scope)" -ForegroundColor Yellow
            }
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
Write-Host "Removed: rg-$GitHubRepo (incl. its ACR + images), $ServicePrincipalName, the Easy Auth app, and purged the soft-deleted Key Vault(s) + Easy Auth app so a same-name re-onboard works" -ForegroundColor Green
switch ($GitHubRepoAction) {
    "keep"    { Write-Host "The GitHub repository '$repoFullName' was kept." -ForegroundColor Cyan }
    "archive" { Write-Host "The GitHub repository '$repoFullName' was archived (read-only)." -ForegroundColor Cyan }
    "delete"  { Write-Host "The GitHub repository '$repoFullName' was deleted." -ForegroundColor Cyan }
}
Write-Host "Remember to remove '$GitHubRepo' from repos.json (the workflow does this)." -ForegroundColor Cyan
Write-Host ""
