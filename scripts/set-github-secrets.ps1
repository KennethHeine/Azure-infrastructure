# Set GitHub Secrets for Azure OIDC Authentication
# This script sets the required GitHub repository secrets using the GitHub CLI (gh).
#
# Prerequisites:
#   - GitHub CLI installed (https://cli.github.com)
#   - Authenticated with: gh auth login
#
# Usage:
#   .\scripts\set-github-secrets.ps1
#   .\scripts\set-github-secrets.ps1 -Repo "KennethHeine/Azure-infrastructure"

[CmdletBinding()]
param(
    [string]$Repo = "KennethHeine/Azure-infrastructure",

    [string]$ClientId = "36806ef6-f366-45c1-8d88-f1cafe02e3ef",

    [string]$TenantId = "14bc2ff7-5fd1-4ce2-a110-4f71b9a2ce41",

    [string]$SubscriptionId = "bb732a02-2579-488d-8337-a159f8b1c0a9"
)

$ErrorActionPreference = "Stop"

# Check gh CLI
try {
    $null = Get-Command gh -ErrorAction Stop
} catch {
    Write-Host "Error: GitHub CLI (gh) is not installed." -ForegroundColor Red
    Write-Host "Install it from: https://cli.github.com"
    exit 1
}

Write-Host "Setting GitHub secrets for $Repo..." -ForegroundColor Cyan
Write-Host ""

# Set each secret
$secrets = @{
    "AZURE_CLIENT_ID"       = $ClientId
    "AZURE_TENANT_ID"       = $TenantId
    "AZURE_SUBSCRIPTION_ID" = $SubscriptionId
}

foreach ($secret in $secrets.GetEnumerator()) {
    Write-Host "  Setting $($secret.Key)..." -NoNewline
    $secret.Value | gh secret set $secret.Key --repo $Repo
    if ($LASTEXITCODE -eq 0) {
        Write-Host " done" -ForegroundColor Green
    } else {
        Write-Host " FAILED" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "All secrets set successfully for $Repo" -ForegroundColor Green
