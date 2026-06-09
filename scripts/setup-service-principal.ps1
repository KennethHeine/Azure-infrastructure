# Azure Infrastructure Service Principal Setup
# This script creates the SERVICE PRINCIPAL for THIS repo (Azure-infrastructure).
# It needs:
#   1. Owner role on subscription (to create RGs and assign roles to other SPs)
#   2. Microsoft Graph Application.ReadWrite.All (to create app registrations, SPs, and federated credentials for other repos)
#   3. Microsoft Graph AppRoleAssignment.ReadWrite.All (to grant each container-app
#      repo's SP the Application.ReadWrite.OwnedBy role, so that repo can create its
#      own Entra "Easy Auth" application at deploy time)
#
# Run this script ONCE manually with an account that has Global Administrator or
# Privileged Role Administrator to grant admin consent for the Graph API permissions.
# It is idempotent — safe to re-run to add newly-required permissions.

[CmdletBinding()]
param(
    [string]$GitHubOrg = "KennethHeine",

    [string]$GitHubRepo = "Azure-infrastructure",

    [string]$ServicePrincipalName = "sp-azure-infrastructure-github"
)

# Stop on first error
$ErrorActionPreference = "Stop"

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Azure Infrastructure SP Setup" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "GitHub Org/User: $GitHubOrg"
Write-Host "GitHub Repo:     $GitHubRepo"
Write-Host "Service Principal: $ServicePrincipalName"
Write-Host ""

# ─── Prerequisites ───────────────────────────────────────────────────
try {
    $null = Get-Command az -ErrorAction Stop
} catch {
    Write-Host "Error: Azure CLI is not installed. Please install it first." -ForegroundColor Red
    Write-Host "Visit: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
}

Write-Host "Checking Azure CLI authentication..."
try {
    $accountJson = az account show --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Not authenticated"
    }
    $accountInfo = $accountJson | ConvertFrom-Json
    $subscriptionId = $accountInfo.id
    $tenantId = $accountInfo.tenantId
} catch {
    Write-Host "Error: You are not logged in to Azure CLI." -ForegroundColor Red
    Write-Host "Please run 'az login' first."
    exit 1
}

Write-Host "Authenticated with Azure" -ForegroundColor Green
Write-Host "  Subscription ID: $subscriptionId"
Write-Host "  Tenant ID:       $tenantId"
Write-Host ""

# ─── Step 1: Create the App Registration ─────────────────────────────
Write-Host "Step 1: Creating app registration '$ServicePrincipalName'..." -ForegroundColor Cyan

$existingAppId = az ad app list --display-name $ServicePrincipalName --query "[0].appId" --output tsv --only-show-errors

if ($existingAppId) {
    Write-Host "  App registration already exists (appId: $existingAppId)" -ForegroundColor Yellow
    $appId = $existingAppId
} else {
    $appId = az ad app create --display-name $ServicePrincipalName --query "appId" --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not $appId) {
        Write-Host "Error: Failed to create app registration" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Created app registration (appId: $appId)" -ForegroundColor Green
}

# ─── Step 2: Ensure the Service Principal exists ─────────────────────
Write-Host "Step 2: Ensuring service principal exists..." -ForegroundColor Cyan

$spObjectId = az ad sp list --display-name $ServicePrincipalName --query "[?appId=='$appId'].id | [0]" --output tsv --only-show-errors

if (-not $spObjectId) {
    az ad sp create --id $appId --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Failed to create service principal" -ForegroundColor Red
        exit 1
    }
    Start-Sleep -Seconds 5
    $spObjectId = az ad sp list --display-name $ServicePrincipalName --query "[?appId=='$appId'].id | [0]" --output tsv --only-show-errors
    Write-Host "  Created service principal (objectId: $spObjectId)" -ForegroundColor Green
} else {
    Write-Host "  Service principal already exists (objectId: $spObjectId)" -ForegroundColor Yellow
}

# ─── Step 3: Assign Owner role on the subscription ───────────────────
Write-Host "Step 3: Assigning Owner role on subscription..." -ForegroundColor Cyan

$existingRole = az role assignment list `
    --assignee $appId `
    --role "Owner" `
    --scope "/subscriptions/$subscriptionId" `
    --query "[0].id" --output tsv --only-show-errors

if ($existingRole) {
    Write-Host "  Owner role already assigned" -ForegroundColor Yellow
} else {
    az role assignment create `
        --assignee $appId `
        --role "Owner" `
        --scope "/subscriptions/$subscriptionId" --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Failed to assign Owner role" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Owner role assigned on subscription" -ForegroundColor Green
}

# ─── Step 4: Grant Microsoft Graph API permissions ───────────────────
Write-Host "Step 4: Granting Microsoft Graph API permissions..." -ForegroundColor Cyan

# Microsoft Graph well-known appId
$graphAppId = "00000003-0000-0000-c000-000000000000"

# Graph application permissions (app roles) this SP needs. App role IDs are
# constant across all tenants.
#   Application.ReadWrite.All       -> create app registrations, SPs, and
#                                      federated credentials for onboarded repos
#   AppRoleAssignment.ReadWrite.All -> grant each container-app repo's SP the
#                                      Application.ReadWrite.OwnedBy role, so that
#                                      repo's own deploy can create its Entra
#                                      "Easy Auth" application via Microsoft Graph
$graphPermissions = [ordered]@{
    "Application.ReadWrite.All"       = "1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9"
    "AppRoleAssignment.ReadWrite.All" = "06b708a9-e830-4db3-a914-8e69da51d44f"
}

$existingPermissions = az ad app permission list --id $appId --only-show-errors --output json | ConvertFrom-Json
foreach ($perm in $graphPermissions.GetEnumerator()) {
    $hasPermission = $existingPermissions | Where-Object { $_.resourceAppId -eq $graphAppId } |
        ForEach-Object { $_.resourceAccess } |
        Where-Object { $_.id -eq $perm.Value -and $_.type -eq "Role" }

    if ($hasPermission) {
        Write-Host "  $($perm.Key) already configured" -ForegroundColor Yellow
    } else {
        az ad app permission add `
            --id $appId `
            --api $graphAppId `
            --api-permissions "$($perm.Value)=Role" --only-show-errors 2>&1 | Out-Null
        Write-Host "  Added $($perm.Key) to app registration" -ForegroundColor Green
    }
}

# ─── Exchange Online app permission (manage EXO config as code) ───────
# The Office 365 Exchange Online resource (well-known appId) exposes the
# Exchange.ManageAsApp application role. With it (plus the Exchange Administrator
# directory role assigned in Step 4b), this SP can connect to Exchange Online
# PowerShell app-only via an access token minted from its OIDC login — no
# certificate or stored secret required. See scripts/deploy-exchange.ps1.
$exoResourceAppId   = "00000002-0000-0ff1-ce00-000000000000"  # Office 365 Exchange Online
$exoManageAsAppRole = "dc50a0fb-09a3-484d-be87-e023b12c6440"  # Exchange.ManageAsApp (app role)

$hasExoPermission = $existingPermissions | Where-Object { $_.resourceAppId -eq $exoResourceAppId } |
    ForEach-Object { $_.resourceAccess } |
    Where-Object { $_.id -eq $exoManageAsAppRole -and $_.type -eq "Role" }

if ($hasExoPermission) {
    Write-Host "  Exchange.ManageAsApp already configured" -ForegroundColor Yellow
} else {
    az ad app permission add `
        --id $appId `
        --api $exoResourceAppId `
        --api-permissions "$exoManageAsAppRole=Role" --only-show-errors 2>&1 | Out-Null
    Write-Host "  Added Exchange.ManageAsApp to app registration" -ForegroundColor Green
}

# Grant admin consent for all configured permissions (idempotent — safe to re-run).
Write-Host "  Granting admin consent (requires Global Admin or Privileged Role Admin)..." -ForegroundColor Gray
az ad app permission admin-consent --id $appId --only-show-errors 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Admin consent granted" -ForegroundColor Green
} else {
    Write-Host "  WARNING: Admin consent failed. Ask a Global Admin to grant consent for the" -ForegroundColor Red
    Write-Host "  Graph permissions above on app '$ServicePrincipalName' ($appId)." -ForegroundColor Red
    Write-Host "  Without them, the infra repo cannot onboard repos or enable Entra auth." -ForegroundColor Red
}

# ─── Step 4b: Assign the Exchange Administrator directory role to the SP ──
# For app-only Exchange Online connections, the RBAC the session gets is derived
# from the directory role baked into the access token. Exchange Administrator lets
# the SP run the DKIM/org cmdlets in scripts/deploy-exchange.ps1. (Can be tightened
# later to a custom Exchange role group via New-ServicePrincipal/Add-RoleGroupMember
# if a narrower scope than the full Exchange Administrator role is wanted.)
Write-Host "Step 4b: Assigning Exchange Administrator directory role to the SP..." -ForegroundColor Cyan
$exchangeAdminRoleTemplateId = "29232cdf-9323-42fd-ade2-1d097af3e4de"

# Directory roles must be activated from their template before members can be added.
$roleListJson = az rest --method get `
    --url "https://graph.microsoft.com/v1.0/directoryRoles?`$filter=roleTemplateId eq '$exchangeAdminRoleTemplateId'" `
    --only-show-errors
$roleId = ($roleListJson | ConvertFrom-Json).value[0].id

if (-not $roleId) {
    Write-Host "  Activating Exchange Administrator directory role..." -ForegroundColor Gray
    $activateBody = Join-Path $env:TEMP "exo-role-activate.json"
    "{`"roleTemplateId`": `"$exchangeAdminRoleTemplateId`"}" | Out-File -FilePath $activateBody -Encoding utf8
    $roleId = (az rest --method post `
        --url "https://graph.microsoft.com/v1.0/directoryRoles" `
        --headers "Content-Type=application/json" `
        --body "@$activateBody" --only-show-errors | ConvertFrom-Json).id
    Remove-Item $activateBody -ErrorAction SilentlyContinue
}

# Idempotent membership check, then add the SP as a member of the role.
$membersJson = az rest --method get `
    --url "https://graph.microsoft.com/v1.0/directoryRoles/$roleId/members?`$select=id" `
    --only-show-errors
$isMember = ($membersJson | ConvertFrom-Json).value | Where-Object { $_.id -eq $spObjectId }

if ($isMember) {
    Write-Host "  SP already has the Exchange Administrator role" -ForegroundColor Yellow
} else {
    $refBody = Join-Path $env:TEMP "exo-role-member.json"
    "{`"@odata.id`": `"https://graph.microsoft.com/v1.0/directoryObjects/$spObjectId`"}" | Out-File -FilePath $refBody -Encoding utf8
    az rest --method post `
        --url "https://graph.microsoft.com/v1.0/directoryRoles/$roleId/members/`$ref" `
        --headers "Content-Type=application/json" `
        --body "@$refBody" --only-show-errors 2>&1 | Out-Null
    Remove-Item $refBody -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Assigned Exchange Administrator role to the SP" -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Could not assign Exchange Administrator role — assign it manually" -ForegroundColor Yellow
    }
}

# ─── Step 5: Create federated credentials for THIS repo ─────────────
Write-Host "Step 5: Creating federated credentials for GitHub Actions..." -ForegroundColor Cyan

# Helper function to create a federated credential (idempotent)
function Add-FederatedCredential {
    param(
        [string]$Name,
        [string]$Subject,
        [string]$Description
    )

    $existing = az ad app federated-credential list --id $appId --query "[?name=='$Name'].name" --output tsv --only-show-errors
    if ($existing) {
        Write-Host "  Federated credential '$Name' already exists" -ForegroundColor Yellow
        return
    }

    $credJson = @"
{
    "name": "$Name",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "$Subject",
    "description": "$Description",
    "audiences": ["api://AzureADTokenExchange"]
}
"@

    $tempFile = Join-Path $env:TEMP "fc-$Name.json"
    $credJson | Out-File -FilePath $tempFile -Encoding utf8

    az ad app federated-credential create --id $appId --parameters $tempFile --only-show-errors 2>&1 | Out-Null

    Remove-Item -Path $tempFile -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Created federated credential '$Name'" -ForegroundColor Green
    } else {
        Write-Host "  Failed to create federated credential '$Name'" -ForegroundColor Red
    }
}

# Main branch only. This SP is Owner on the whole subscription, so it must NOT
# trust pull_request OIDC tokens: a PR-triggered workflow (or a "pwn-request")
# could otherwise mint a subscription-Owner token. Onboarding only ever runs on
# push-to-main / workflow_dispatch, so a main-branch credential is sufficient.
Add-FederatedCredential `
    -Name "github-actions-main" `
    -Subject "repo:$GitHubOrg/${GitHubRepo}:ref:refs/heads/main" `
    -Description "GitHub Actions - main branch deployments"

# Remove the legacy pull_request federated credential if a previous run created
# it — it is an unused attack surface on a subscription-Owner identity.
$prCred = az ad app federated-credential list --id $appId --query "[?name=='github-actions-pr'].id | [0]" --output tsv --only-show-errors
if ($prCred) {
    az ad app federated-credential delete --id $appId --federated-credential-id $prCred --only-show-errors 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Removed legacy 'github-actions-pr' federated credential (not needed; reduces attack surface)" -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Could not remove legacy 'github-actions-pr' federated credential — delete it manually" -ForegroundColor Yellow
    }
    $global:LASTEXITCODE = 0
}

Write-Host ""

# ─── Summary ─────────────────────────────────────────────────────────
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Setup Complete" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Infrastructure SP Permissions:" -ForegroundColor Green
Write-Host "  - Owner role on subscription $subscriptionId"
Write-Host "  - Microsoft Graph: Application.ReadWrite.All (create SPs for other repos)"
Write-Host "  - Microsoft Graph: AppRoleAssignment.ReadWrite.All (grant repo SPs Application.ReadWrite.OwnedBy for Easy Auth)"
Write-Host "  - Office 365 Exchange Online: Exchange.ManageAsApp (manage Exchange Online config as code)"
Write-Host "  - Directory role: Exchange Administrator (RBAC for app-only EXO connections)"
Write-Host ""
Write-Host "Add these secrets to the '$GitHubRepo' GitHub repository:" -ForegroundColor Yellow
Write-Host "  Settings > Secrets and variables > Actions > New repository secret"
Write-Host ""
Write-Host "  AZURE_CLIENT_ID:        $appId" -ForegroundColor Yellow
Write-Host "  AZURE_TENANT_ID:        $tenantId" -ForegroundColor Yellow
Write-Host "  AZURE_SUBSCRIPTION_ID:  $subscriptionId" -ForegroundColor Yellow
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Add the GitHub secrets above"
Write-Host "  2. Use 'scripts/create-repo-infrastructure.ps1' to onboard new repos"
Write-Host "  3. Each onboarded repo gets: a Resource Group + SP + federated credentials"
Write-Host ""
