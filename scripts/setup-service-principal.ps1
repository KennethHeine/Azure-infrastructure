# Azure Infrastructure Service Principal Setup
# This script creates the SERVICE PRINCIPAL for THIS repo (Azure-infrastructure).
# It needs:
#   1. Owner role on subscription (to create RGs and assign roles to other SPs)
#   2. Microsoft Graph Application.ReadWrite.All (to create app registrations, SPs, and federated credentials for other repos)
#
# Run this script ONCE manually with an account that has Global Administrator or
# Privileged Role Administrator to grant admin consent for the Graph API permissions.

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
Write-Host "  (Application.ReadWrite.All — required to create SPs and federated credentials for other repos)" -ForegroundColor Gray

# Microsoft Graph well-known appId
$graphAppId = "00000003-0000-0000-c000-000000000000"

# Application.ReadWrite.All app role ID (constant across all tenants)
$appReadWriteAllId = "1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9"

# Add the API permission to the app registration
az ad app permission add `
    --id $appId `
    --api $graphAppId `
    --api-permissions "${appReadWriteAllId}=Role" --only-show-errors 2>&1 | Out-Null

Write-Host "  API permission added to app registration" -ForegroundColor Green

# Grant admin consent
Write-Host "  Granting admin consent (requires Global Admin or Privileged Role Admin)..." -ForegroundColor Gray
az ad app permission admin-consent --id $appId --only-show-errors 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "  Admin consent granted" -ForegroundColor Green
} else {
    Write-Host "  WARNING: Admin consent failed. Ask a Global Admin to grant consent for" -ForegroundColor Red
    Write-Host "  Application.ReadWrite.All on app '$ServicePrincipalName' ($appId)" -ForegroundColor Red
    Write-Host "  Without this, the infra repo cannot create SPs for other repos." -ForegroundColor Red
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

# Main branch
Add-FederatedCredential `
    -Name "github-actions-main" `
    -Subject "repo:$GitHubOrg/${GitHubRepo}:ref:refs/heads/main" `
    -Description "GitHub Actions - main branch deployments"

# Pull requests
Add-FederatedCredential `
    -Name "github-actions-pr" `
    -Subject "repo:$GitHubOrg/${GitHubRepo}:pull_request" `
    -Description "GitHub Actions - pull request validation"

Write-Host ""

# ─── Summary ─────────────────────────────────────────────────────────
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Setup Complete" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Infrastructure SP Permissions:" -ForegroundColor Green
Write-Host "  - Owner role on subscription $subscriptionId"
Write-Host "  - Microsoft Graph: Application.ReadWrite.All (create SPs for other repos)"
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
