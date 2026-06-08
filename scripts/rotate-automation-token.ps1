# Rotate the GitHub automation token (AUTOMATION_GITHUB_TOKEN)
#
# GitHub does not allow personal access tokens to be minted via the API, so a
# rotation can't be fully automated. This script does everything around that
# manual step:
#
#   1. If no token is supplied, prints the exact URL + scopes to create one.
#   2. Validates the new token (delegates to test-automation-token.ps1).
#   3. Writes it to the AUTOMATION_GITHUB_TOKEN repo secret using your own
#      (admin) gh login — not the new token.
#   4. Optionally re-runs the onboarding workflow so you can confirm it's green.
#
# The secret is written with your ambient `gh auth login` identity, so you must
# be authenticated (gh auth status) with admin rights on the target repo.
#
# Usage:
#   # Print instructions for creating a new token:
#   .\scripts\rotate-automation-token.ps1
#
#   # Rotate with a freshly created token:
#   .\scripts\rotate-automation-token.ps1 -NewToken 'ghp_xxx'
#
#   # ...or pass it via env to keep it out of shell history:
#   $env:NEW_AUTOMATION_GITHUB_TOKEN = 'ghp_xxx'
#   .\scripts\rotate-automation-token.ps1
#
#   # Rotate and immediately re-run the onboarding workflow:
#   .\scripts\rotate-automation-token.ps1 -NewToken 'ghp_xxx' -Dispatch

[CmdletBinding()]
param(
    [string]$NewToken = $env:NEW_AUTOMATION_GITHUB_TOKEN,

    [string]$Repo = "KennethHeine/Azure-infrastructure",

    [string]$SecretName = "AUTOMATION_GITHUB_TOKEN",

    [string]$Org = "KennethHeine",

    [string]$Workflow = "onboard-repos.yml",

    # Re-run the onboarding workflow after a successful rotation.
    [switch]$Dispatch
)

$ErrorActionPreference = "Stop"

# Pre-filled token creation URL: classic PAT with the scopes Step 6+ needs
# (repo = create repos + set Actions secrets; workflow = manage workflow files).
$createUrl = "https://github.com/settings/tokens/new?scopes=repo,workflow&description=Azure-infrastructure%20automation"

# gh CLI required
try {
    $null = Get-Command gh -ErrorAction Stop
} catch {
    Write-Host "Error: GitHub CLI (gh) is not installed. Install it from https://cli.github.com" -ForegroundColor Red
    exit 1
}

# Caller must be logged in with admin rights to set the secret.
gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: You are not logged in to gh. Run 'gh auth login' first (admin on $Repo required)." -ForegroundColor Red
    exit 1
}

if (-not $NewToken) {
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "Rotate $SecretName" -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "No token supplied. Create a new one, then re-run this script." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "1. Create a classic PAT with the 'repo' and 'workflow' scopes:" -ForegroundColor Cyan
    Write-Host "   $createUrl"
    Write-Host ""
    Write-Host "   (Fine-grained alternative: grant Administration + Contents + Secrets" -ForegroundColor Gray
    Write-Host "    read/write on the repos you onboard.)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "2. Re-run with the token:" -ForegroundColor Cyan
    Write-Host "   .\scripts\rotate-automation-token.ps1 -NewToken '<token>'" -ForegroundColor Gray
    Write-Host "   # or:  `$env:NEW_AUTOMATION_GITHUB_TOKEN = '<token>'; .\scripts\rotate-automation-token.ps1" -ForegroundColor Gray
    Write-Host ""
    exit 0
}

# ─── Validate the new token before storing it ────────────────────────
$validator = Join-Path $PSScriptRoot "test-automation-token.ps1"
if (-not (Test-Path $validator)) {
    Write-Host "Error: Validator not found: $validator" -ForegroundColor Red
    exit 1
}

Write-Host "Step 1: Validating the new token..." -ForegroundColor Cyan
& $validator -Token $NewToken -Org $Org
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Error: The new token is not valid. Nothing was changed." -ForegroundColor Red
    exit 1
}
Write-Host ""

# ─── Store the token in the repo secret (uses your admin gh login) ───
Write-Host "Step 2: Writing secret '$SecretName' to '$Repo'..." -ForegroundColor Cyan
$NewToken | gh secret set $SecretName --repo $Repo
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to set secret '$SecretName' on '$Repo'." -ForegroundColor Red
    Write-Host "Make sure your gh login has admin rights on the repository." -ForegroundColor Red
    exit 1
}
Write-Host "  Secret '$SecretName' updated" -ForegroundColor Green
Write-Host ""

# ─── Optionally re-run the onboarding workflow ───────────────────────
if ($Dispatch) {
    Write-Host "Step 3: Dispatching workflow '$Workflow' on '$Repo'..." -ForegroundColor Cyan
    gh workflow run $Workflow --repo $Repo
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: Failed to dispatch '$Workflow' — trigger it manually from the Actions tab." -ForegroundColor Yellow
    } else {
        Write-Host "  Workflow dispatched. Watch it with:" -ForegroundColor Green
        Write-Host "    gh run watch --repo $Repo" -ForegroundColor Gray
        Write-Host "  or list recent runs:" -ForegroundColor Green
        Write-Host "    gh run list --repo $Repo --workflow $Workflow" -ForegroundColor Gray
    }
    Write-Host ""
}

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Rotation complete" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
if (-not $Dispatch) {
    Write-Host ""
    Write-Host "Re-run the onboarding workflow to confirm it's green:" -ForegroundColor Cyan
    Write-Host "  gh workflow run $Workflow --repo $Repo" -ForegroundColor Gray
}
Write-Host ""
