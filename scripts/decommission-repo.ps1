# Decommission a repository's Azure + GitHub footprint.
#
# Tears down everything the onboarding created for a single repo:
#   1. Deletes the app registration sp-<repo>-github (removes the SP + its
#      federated credentials + its rg-scoped role assignments)
#   2. Deletes the resource group rg-<repo> (Container App, env, Log Analytics,
#      the repo's own ACR + images, managed identity, etc.)
#   3. Tears down the preview environment too if the repo had one
#      ("preview": true): sp-<repo>-preview-github (+ its Easy Auth app) and
#      rg-<repo>-preview (Step 3c).
#   4. Purges the repo's images + ABAC role assignments from the estate-wide
#      shared registry acrkscloud (Step 3d).
#   5. (Optional) Archives (read-only) or deletes the GitHub repository
#
# The repo's container images used to live in an ACR inside rg-<repo> and died
# with the resource group. Since the 2026-08-06 consolidation they live in the
# shared acrkscloud (rg-acr) under a '<repo>/' prefix, and the repo's registry
# grants are role assignments on THAT registry — so both now outlive the
# resource group and have to be cleaned up explicitly (Step 3d), or the repo
# keeps costing storage after it's gone.
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

# ─── Step 0: Capture the principals holding grants on the shared ACR ─
# Since the registry consolidation (2026-08-06) a repo's images and its
# registry role assignments no longer live inside rg-<repo> — they're in the
# estate-wide acrkscloud (rg-acr) — so neither deleting the SP (Step 2) nor
# deleting the resource groups (Steps 3/3c) cleans them up. Step 3d does, but
# it needs the principal ids, and by then the objects that carry them are gone:
# a UAMI's principalId is unrecoverable once its resource group is deleted.
# So collect them here, first, while everything still exists.
$sharedAcrName = "acrkscloud"
$sharedAcrPrincipalIds = @()

foreach ($spName in @($ServicePrincipalName, "sp-$GitHubRepo-preview-github")) {
    $objId = az ad sp list --display-name $spName --query "[0].id" --output tsv --only-show-errors
    if ($objId) { $sharedAcrPrincipalIds += $objId }
    $global:LASTEXITCODE = 0
}
foreach ($rg in @($ResourceGroupName, "rg-$GitHubRepo-preview")) {
    if ((az group exists --name $rg --only-show-errors) -eq "true") {
        foreach ($id in @(az identity list -g $rg --query "[].principalId" --output tsv --only-show-errors)) {
            if ($id) { $sharedAcrPrincipalIds += $id }
        }
    }
    $global:LASTEXITCODE = 0
}
$sharedAcrPrincipalIds = @($sharedAcrPrincipalIds | Sort-Object -Unique)
Write-Host "Step 0: Captured $($sharedAcrPrincipalIds.Count) principal(s) that may hold grants on '$sharedAcrName'" -ForegroundColor Cyan
Write-Host ""

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

# ─── Step 2b: Release Azure Backup before the RG can be deleted ──────
# A Recovery Services vault protecting a storage account auto-creates an
# `AzureBackupProtectionLock` (CanNotDelete) ON THE STORAGE ACCOUNT. That lock
# makes `az group delete` fail with no useful message — which is exactly how the
# claude-coder decommission failed on 2026-07-25. Any repo whose shares are
# backed up (see the Azure Files backup work) hits this.
#
# Order matters: soft delete must be turned OFF first, otherwise disabling
# protection leaves the items in a soft-deleted state for 14 days and the vault
# (and therefore the RG) still refuses to go.
Write-Host "Step 2b: Releasing Azure Backup protection in '$ResourceGroupName'..." -ForegroundColor Cyan
$vaults = @()
if ((az group exists --name $ResourceGroupName --only-show-errors) -eq "true") {
    $vaults = @(az backup vault list -g $ResourceGroupName --query "[].name" -o tsv --only-show-errors 2>$null)
}
if (-not $vaults -or $vaults.Count -eq 0) {
    Write-Host "  No Recovery Services vault — nothing to release" -ForegroundColor Yellow
} else {
    foreach ($vault in $vaults) {
        Write-Host "  Vault '$vault':" -ForegroundColor Cyan
        # 1. Disable soft delete so 'delete backup data' is immediate.
        az backup vault backup-properties set --name $vault -g $ResourceGroupName `
            --soft-delete-feature-state Disable --only-show-errors 2>&1 | Out-Null
        $global:LASTEXITCODE = 0
        # 2. Stop protection + delete the backup data for every protected item.
        $items = az backup item list --vault-name $vault -g $ResourceGroupName `
            --query "[].{name:name,container:properties.containerName,type:properties.backupManagementType,friendly:properties.friendlyName}" `
            -o json --only-show-errors 2>$null | ConvertFrom-Json
        foreach ($item in @($items)) {
            Write-Host "    disabling protection for '$($item.friendly)'" -ForegroundColor Cyan
            az backup protection disable --vault-name $vault -g $ResourceGroupName `
                --container-name $item.container --item-name $item.name `
                --backup-management-type $item.type --delete-backup-data true --yes `
                --only-show-errors 2>&1 | Out-Null
            $global:LASTEXITCODE = 0
        }
        # 3. Unregister the containers so the protection lock is released.
        $containers = az backup container list --vault-name $vault -g $ResourceGroupName `
            --backup-management-type AzureStorage --query "[].name" -o tsv --only-show-errors 2>$null
        foreach ($container in @($containers)) {
            az backup container unregister --vault-name $vault -g $ResourceGroupName `
                --container-name $container --backup-management-type AzureStorage --yes `
                --only-show-errors 2>&1 | Out-Null
            $global:LASTEXITCODE = 0
        }
    }
    # 4. Belt and braces: drop any AzureBackupProtectionLock still standing.
    $locks = az lock list -g $ResourceGroupName --query "[?name=='AzureBackupProtectionLock'].id" -o tsv --only-show-errors 2>$null
    foreach ($lock in @($locks)) {
        if ($lock) {
            az lock delete --ids $lock --only-show-errors 2>&1 | Out-Null
            Write-Host "    removed AzureBackupProtectionLock" -ForegroundColor Green
            $global:LASTEXITCODE = 0
        }
    }
    Write-Host "  Backup protection released" -ForegroundColor Green
}
$global:LASTEXITCODE = 0
Write-Host ""

# ─── Step 3: Delete the resource group (incl. the repo's own ACR) ────
Write-Host "Step 3: Deleting resource group '$ResourceGroupName'..." -ForegroundColor Cyan
$rgExists = az group exists --name $ResourceGroupName --only-show-errors
if ($rgExists -eq "true") {
    $deleteOutput = az group delete --name $ResourceGroupName --yes --only-show-errors 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Deleted resource group '$ResourceGroupName'" -ForegroundColor Green
    } else {
        # Print the reason — a swallowed error here cost a debugging round.
        Write-Host "Error: Failed to delete resource group '$ResourceGroupName'" -ForegroundColor Red
        Write-Host ($deleteOutput | Out-String) -ForegroundColor Red
        Write-Host "  Check for resource locks: az lock list -g $ResourceGroupName" -ForegroundColor Yellow
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

# ─── Step 3c: Tear down the preview environment (if any) ─────────────
# Repos onboarded with "preview": true also have an isolated
# sp-<repo>-preview-github (+ its own Easy Auth app) and rg-<repo>-preview
# (its own ACR/app/vault/identity). Mirror Steps 1-3b for them so a
# decommission leaves no preview footprint behind. Best-effort + idempotent.
$previewSpName = "sp-$GitHubRepo-preview-github"
$previewRgName = "rg-$GitHubRepo-preview"
$previewAppId  = az ad app list --display-name $previewSpName --query "[0].appId" --output tsv --only-show-errors
$previewRgExists = az group exists --name $previewRgName --only-show-errors
if ($previewAppId -or $previewRgExists -eq "true") {
    Write-Host "Step 3c: Tearing down preview environment ($previewSpName + $previewRgName)..." -ForegroundColor Cyan

    # Entra apps owned by the preview SP (its Easy Auth app) — delete + purge so
    # the uniqueName is freed for a same-name re-onboard (see Step 1).
    if ($previewAppId) {
        $previewSpObjId = az ad sp list --display-name $previewSpName --query "[0].id" --output tsv --only-show-errors
        if ($previewSpObjId) {
            $ownedJsonPv = az rest --method GET `
                --url "https://graph.microsoft.com/v1.0/servicePrincipals/$previewSpObjId/ownedObjects" `
                --output json --only-show-errors 2>&1
            if ($LASTEXITCODE -eq 0 -and $ownedJsonPv) {
                $ownedPv = $ownedJsonPv | ConvertFrom-Json
                foreach ($app in @($ownedPv.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.application' -and $_.appId -ne $previewAppId })) {
                    az ad app delete --id $app.appId --only-show-errors 2>&1 | Out-Null
                    az rest --method DELETE --url "https://graph.microsoft.com/v1.0/directory/deletedItems/$($app.id)" --only-show-errors 2>&1 | Out-Null
                    Write-Host "  Deleted + purged preview Entra app '$($app.displayName)'" -ForegroundColor Green
                    $global:LASTEXITCODE = 0
                }
            }
        }
        # Delete the preview app registration (removes the SP + the wildcard FIC).
        az ad app delete --id $previewAppId --only-show-errors 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Deleted preview app registration ($previewAppId)" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: failed to delete preview app registration $previewAppId" -ForegroundColor Yellow
        }
        $global:LASTEXITCODE = 0
    }

    # Delete the preview RG (its own ACR + app + vault + identity).
    if ($previewRgExists -eq "true") {
        az group delete --name $previewRgName --yes --only-show-errors 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Deleted resource group '$previewRgName'" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: failed to delete '$previewRgName'" -ForegroundColor Yellow
        }
        $global:LASTEXITCODE = 0
    }

    # Purge soft-deleted Key Vaults that belonged to the preview RG (Step 3b).
    $allDeletedPv = az keyvault list-deleted -o json --only-show-errors 2>$null | ConvertFrom-Json
    foreach ($v in @($allDeletedPv | Where-Object { $_.properties.vaultId -like "*/resourceGroups/$previewRgName/*" })) {
        az keyvault purge --name $v.name --location $v.properties.location --only-show-errors 2>&1 | Out-Null
        Write-Host "  Purged soft-deleted preview vault '$($v.name)'" -ForegroundColor Green
        $global:LASTEXITCODE = 0
    }
    Write-Host ""
} else {
    Write-Host "Step 3c: No preview environment for '$GitHubRepo' — skipping" -ForegroundColor Yellow
    Write-Host ""
}

# ─── Step 3d: Purge this repo from the estate-wide shared ACR ────────
# Before the 2026-08-06 consolidation each repo's registry lived inside
# rg-<repo> and died with it. Now every repo's images sit in the shared
# acrkscloud under a '<repo>/' prefix, and its ABAC role assignments are on
# that registry — neither is touched by deleting the SP or the resource groups.
# Without this step a decommissioned repo keeps paying for image storage
# indefinitely and leaves orphaned role assignments behind.
#
# Prefix matching is exact-with-slash on purpose: '<repo>/' cannot match
# '<repo>-preview/' (which gets its own entry, mirroring how deploy-app
# namespaces preview builds), and the cached Docker Hub base images live at the
# registry ROOT, shared across every repo — never under a repo prefix — so they
# are never caught by this.
#
# This needs data-plane rights that the onboarding SP's subscription Owner role
# does NOT confer under ABAC: registry-wide Repository Contributor (delete) and
# Catalog Lister (enumerate), both granted in acr/main.bicep. Best-effort
# throughout — a failure here must never block or fail the teardown.
Write-Host "Step 3d: Purging '$GitHubRepo' from the shared registry '$sharedAcrName'..." -ForegroundColor Cyan
$sharedAcrId = az acr show --name $sharedAcrName --query id --output tsv --only-show-errors 2>$null
$global:LASTEXITCODE = 0
if (-not $sharedAcrId) {
    Write-Host "  Shared registry '$sharedAcrName' not found — skipping" -ForegroundColor Yellow
} else {
    # 1. Image repositories under this repo's prefixes.
    $prefixes = @("$GitHubRepo/", "$GitHubRepo-preview/")
    $repoListJson = az acr repository list --name $sharedAcrName --output json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $repoListJson) {
        Write-Host "  WARNING: could not list repositories — images NOT purged." -ForegroundColor Yellow
        Write-Host "           The onboarding SP needs Catalog Lister on '$sharedAcrName' (acr/main.bicep)." -ForegroundColor Yellow
    } else {
        $mine = @(($repoListJson | ConvertFrom-Json) | Where-Object {
            $name = $_
            @($prefixes | Where-Object { $name.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        })
        if ($mine.Count -eq 0) {
            Write-Host "  No '$GitHubRepo/' image repositories in '$sharedAcrName'" -ForegroundColor Yellow
        }
        foreach ($imageRepo in $mine) {
            az acr repository delete --name $sharedAcrName --repository $imageRepo --yes --only-show-errors 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Deleted image repository '$imageRepo'" -ForegroundColor Green
            } else {
                Write-Host "  WARNING: failed to delete image repository '$imageRepo'" -ForegroundColor Yellow
            }
            $global:LASTEXITCODE = 0
        }
    }
    $global:LASTEXITCODE = 0

    # 2. ABAC role assignments held by this repo's (now deleted) principals.
    # List once and filter locally on principalId: the principals no longer
    # exist, so --assignee would fail its Microsoft Graph lookup.
    if ($sharedAcrPrincipalIds.Count -eq 0) {
        Write-Host "  No captured principals — no role assignments to remove" -ForegroundColor Yellow
    } else {
        $allRas = az role assignment list --scope $sharedAcrId --output json --only-show-errors 2>$null | ConvertFrom-Json
        $global:LASTEXITCODE = 0
        $stale = @($allRas | Where-Object { $sharedAcrPrincipalIds -contains $_.principalId })
        if ($stale.Count -eq 0) {
            Write-Host "  No role assignments for this repo on '$sharedAcrName'" -ForegroundColor Yellow
        }
        foreach ($ra in $stale) {
            az role assignment delete --ids $ra.id --only-show-errors 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Removed '$($ra.roleDefinitionName)' for $($ra.principalId)" -ForegroundColor Green
            } else {
                Write-Host "  WARNING: failed to remove role assignment $($ra.id)" -ForegroundColor Yellow
            }
            $global:LASTEXITCODE = 0
        }
    }
}
$global:LASTEXITCODE = 0
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
Write-Host "Removed: rg-$GitHubRepo, $ServicePrincipalName, the Easy Auth app, this repo's images + grants on $sharedAcrName, and purged the soft-deleted Key Vault(s) + Easy Auth app so a same-name re-onboard works" -ForegroundColor Green
switch ($GitHubRepoAction) {
    "keep"    { Write-Host "The GitHub repository '$repoFullName' was kept." -ForegroundColor Cyan }
    "archive" { Write-Host "The GitHub repository '$repoFullName' was archived (read-only)." -ForegroundColor Cyan }
    "delete"  { Write-Host "The GitHub repository '$repoFullName' was deleted." -ForegroundColor Cyan }
}
Write-Host "Remember to remove '$GitHubRepo' from repos.json (the workflow does this)." -ForegroundColor Cyan
Write-Host ""
