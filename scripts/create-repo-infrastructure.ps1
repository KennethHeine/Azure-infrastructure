# Create Repository Infrastructure
# This script onboards a single repository. It creates:
#   1. A Resource Group (rg-<repo>)
#   2. A Service Principal (sp-<repo>-github)
#   3. Federated credentials for GitHub Actions OIDC (main branch + pull requests)
#   4. Owner role assignment on the new RG for the repo's SP
#
# Fully idempotent — safe to run multiple times.
#
# Usage:
#   .\create-repo-infrastructure.ps1 -GitHubRepo "my-app"
#   .\create-repo-infrastructure.ps1 -GitHubRepo "my-app" -GitHubOrg "MyOrg" -Location "westeurope"

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GitHubRepo,

    [string]$GitHubOrg = "KennethHeine",

    [string]$Location = "norwayeast"
)

$ErrorActionPreference = "Stop"

# ─── Derive names from repo ──────────────────────────────────────────
$ResourceGroupName = "rg-$GitHubRepo"
$ServicePrincipalName = "sp-$GitHubRepo-github"

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Onboard Repository Infrastructure" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "GitHub Repo:       $GitHubOrg/$GitHubRepo"
Write-Host "Resource Group:    $ResourceGroupName"
Write-Host "Location:          $Location"
Write-Host "Service Principal: $ServicePrincipalName"
Write-Host ""

# ─── Prerequisites ───────────────────────────────────────────────────
try {
    $null = Get-Command az -ErrorAction Stop
} catch {
    Write-Host "Error: Azure CLI is not installed." -ForegroundColor Red
    exit 1
}

Write-Host "Checking Azure CLI authentication..."
try {
    $accountJson = az account show --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Not authenticated" }
    $accountInfo = $accountJson | ConvertFrom-Json
    $subscriptionId = $accountInfo.id
    $tenantId = $accountInfo.tenantId
} catch {
    Write-Host "Error: Not logged in. Run 'az login' first." -ForegroundColor Red
    exit 1
}

Write-Host "  Subscription: $subscriptionId" -ForegroundColor Green
Write-Host "  Tenant:       $tenantId" -ForegroundColor Green
Write-Host ""

# ─── Step 1: Create Resource Group ───────────────────────────────────
Write-Host "Step 1: Creating resource group '$ResourceGroupName' in '$Location'..." -ForegroundColor Cyan

$existingRg = az group show --name $ResourceGroupName --query "name" --output tsv --only-show-errors 2>&1
if ($LASTEXITCODE -eq 0 -and $existingRg -eq $ResourceGroupName) {
    Write-Host "  Resource group already exists" -ForegroundColor Yellow
} else {
    az group create --name $ResourceGroupName --location $Location --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Failed to create resource group" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Resource group created" -ForegroundColor Green
}
Write-Host ""

# ─── Step 2: Create App Registration ─────────────────────────────────
Write-Host "Step 2: Creating app registration '$ServicePrincipalName'..." -ForegroundColor Cyan

$appId = az ad app list --display-name $ServicePrincipalName --query "[0].appId" --output tsv --only-show-errors

if ($appId) {
    Write-Host "  App registration already exists (appId: $appId)" -ForegroundColor Yellow
} else {
    $appId = az ad app create --display-name $ServicePrincipalName --query "appId" --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not $appId) {
        Write-Host "Error: Failed to create app registration" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Created app registration (appId: $appId)" -ForegroundColor Green
    Write-Host "  Waiting for Azure AD replication..." -ForegroundColor Gray
    Start-Sleep -Seconds 15
}
Write-Host ""

# ─── Step 3: Ensure Service Principal exists ─────────────────────────
Write-Host "Step 3: Ensuring service principal exists..." -ForegroundColor Cyan

$spObjectId = az ad sp list --display-name $ServicePrincipalName --query "[?appId=='$appId'].id | [0]" --output tsv --only-show-errors

if (-not $spObjectId) {
    # Retry loop — Azure AD replication can take time after app registration creation
    $maxRetries = 5
    $retryDelay = 10
    $created = $false

    for ($i = 1; $i -le $maxRetries; $i++) {
        az ad sp create --id $appId --only-show-errors 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $created = $true
            break
        }
        Write-Host "  Attempt $i/$maxRetries failed, retrying in ${retryDelay}s..." -ForegroundColor Yellow
        Start-Sleep -Seconds $retryDelay
    }

    if (-not $created) {
        Write-Host "Error: Failed to create service principal after $maxRetries attempts" -ForegroundColor Red
        exit 1
    }

    # Wait for replication
    Start-Sleep -Seconds 5
    $spObjectId = az ad sp list --display-name $ServicePrincipalName --query "[?appId=='$appId'].id | [0]" --output tsv --only-show-errors
    Write-Host "  Created service principal (objectId: $spObjectId)" -ForegroundColor Green
} else {
    Write-Host "  Service principal already exists (objectId: $spObjectId)" -ForegroundColor Yellow
}
Write-Host ""

# ─── Step 4: Assign Owner role on the Resource Group ─────────────────
Write-Host "Step 4: Assigning Owner role on resource group '$ResourceGroupName'..." -ForegroundColor Cyan

$rgScope = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName"

$existingRole = az role assignment list `
    --assignee $appId `
    --role "Owner" `
    --scope $rgScope `
    --query "[0].id" --output tsv --only-show-errors

if ($existingRole) {
    Write-Host "  Owner role already assigned" -ForegroundColor Yellow
} else {
    az role assignment create `
        --assignee $appId `
        --role "Owner" `
        --scope $rgScope --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Failed to assign Owner role" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Owner role assigned on $ResourceGroupName" -ForegroundColor Green
}
Write-Host ""

# ─── Step 5: Create Federated Credentials ────────────────────────────
Write-Host "Step 5: Creating federated credentials..." -ForegroundColor Cyan

function Add-FederatedCredential {
    param(
        [string]$AppId,
        [string]$Name,
        [string]$Subject,
        [string]$Description
    )

    $existing = az ad app federated-credential list --id $AppId --query "[?name=='$Name'].name" --output tsv --only-show-errors
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

    az ad app federated-credential create --id $AppId --parameters $tempFile --only-show-errors 2>&1 | Out-Null

    Remove-Item -Path $tempFile -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Created federated credential '$Name'" -ForegroundColor Green
    } else {
        Write-Host "  Failed to create federated credential '$Name'" -ForegroundColor Red
    }
}

# Federated credential for main branch
Add-FederatedCredential `
    -AppId $appId `
    -Name "github-actions-main" `
    -Subject "repo:$GitHubOrg/${GitHubRepo}:ref:refs/heads/main" `
    -Description "GitHub Actions - main branch"

# Federated credential for pull requests
Add-FederatedCredential `
    -AppId $appId `
    -Name "github-actions-pr" `
    -Subject "repo:$GitHubOrg/${GitHubRepo}:pull_request" `
    -Description "GitHub Actions - pull requests"

Write-Host ""

# ─── Summary ─────────────────────────────────────────────────────────
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Onboarding Complete" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Resource Group:  $ResourceGroupName ($Location)" -ForegroundColor Green
Write-Host "SP App ID:       $appId" -ForegroundColor Green
Write-Host "SP Object ID:    $spObjectId" -ForegroundColor Green
Write-Host "Role:            Owner on $ResourceGroupName" -ForegroundColor Green
Write-Host ""
Write-Host "Add these secrets to the '$GitHubOrg/$GitHubRepo' GitHub repository:" -ForegroundColor Yellow
Write-Host "  Settings > Secrets and variables > Actions > New repository secret"
Write-Host ""
Write-Host "  AZURE_CLIENT_ID:        $appId" -ForegroundColor Yellow
Write-Host "  AZURE_TENANT_ID:        $tenantId" -ForegroundColor Yellow
Write-Host "  AZURE_SUBSCRIPTION_ID:  $subscriptionId" -ForegroundColor Yellow
Write-Host ""
Write-Host "The SP has Owner role ONLY on resource group '$ResourceGroupName'." -ForegroundColor Cyan
Write-Host "It cannot access resources in other resource groups." -ForegroundColor Cyan
Write-Host ""
