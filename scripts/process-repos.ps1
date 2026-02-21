# Process All Repos from repos.json
# Reads the repos.json config file and runs create-repo-infrastructure.ps1 for each repo.
# Idempotent — safe to run multiple times. Existing resources are skipped, not duplicated.
#
# repos.json format:
#   { "gitHubOrg": "KennethHeine", "location": "norwayeast", "repos": ["my-app", "my-api"] }
#
# Usage:
#   .\scripts\process-repos.ps1                      # process all repos
#   .\scripts\process-repos.ps1 -ConfigFile "repos.json"  # explicit config path

[CmdletBinding()]
param(
    [string]$ConfigFile
)

$ErrorActionPreference = "Stop"

# ─── Resolve config file path ────────────────────────────────────────
if (-not $ConfigFile) {
    $repoRoot = if ($PSScriptRoot) {
        Split-Path $PSScriptRoot -Parent
    } else {
        Get-Location
    }
    $ConfigFile = Join-Path $repoRoot "repos.json"
}

if (-not (Test-Path $ConfigFile)) {
    Write-Host "Error: Config file not found: $ConfigFile" -ForegroundColor Red
    exit 1
}

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Process Repository Onboarding" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Config file: $ConfigFile"
Write-Host ""

# ─── Load config ─────────────────────────────────────────────────────
$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

$gitHubOrg = if ($config.gitHubOrg) { $config.gitHubOrg } else { "KennethHeine" }
$location = if ($config.location) { $config.location } else { "norwayeast" }
$repos = $config.repos

if ($repos.Count -eq 0) {
    Write-Host "No repos defined in config file. Nothing to do." -ForegroundColor Yellow
    exit 0
}

Write-Host "GitHub Org: $gitHubOrg" -ForegroundColor Cyan
Write-Host "Location:   $location" -ForegroundColor Cyan
Write-Host "Repos:      $($repos.Count) repo(s) to process" -ForegroundColor Cyan
Write-Host ""

# ─── Resolve path to the onboarding script ───────────────────────────
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { "." }
$onboardScript = Join-Path $scriptDir "create-repo-infrastructure.ps1"

if (-not (Test-Path $onboardScript)) {
    Write-Host "Error: Onboarding script not found: $onboardScript" -ForegroundColor Red
    exit 1
}

# ─── Process each repo ───────────────────────────────────────────────
$successCount = 0
$failCount = 0
$results = @()

foreach ($repoName in $repos) {
    Write-Host "=========================================" -ForegroundColor Magenta
    Write-Host "Processing: $repoName" -ForegroundColor Magenta
    Write-Host "=========================================" -ForegroundColor Magenta
    Write-Host ""

    try {
        & $onboardScript -GitHubRepo $repoName -GitHubOrg $gitHubOrg -Location $location
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "Script exited with code $LASTEXITCODE"
        }
        $successCount++
        $results += [PSCustomObject]@{ Repo = $repoName; Status = "Success" }
        Write-Host "Completed: $repoName" -ForegroundColor Green
    } catch {
        $failCount++
        $results += [PSCustomObject]@{ Repo = $repoName; Status = "FAILED: $_" }
        Write-Host "FAILED: $repoName — $_" -ForegroundColor Red
    }

    Write-Host ""
}

# ─── Summary ─────────────────────────────────────────────────────────
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Processing Complete" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Total:     $($repos.Count)" -ForegroundColor Cyan
Write-Host "Succeeded: $successCount" -ForegroundColor Green
if ($failCount -gt 0) {
    Write-Host "Failed:    $failCount" -ForegroundColor Red
}
Write-Host ""

Write-Host "Results:" -ForegroundColor Cyan
$results | ForEach-Object {
    $color = if ($_.Status -eq "Success") { "Green" } else { "Red" }
    Write-Host "  $($_.Repo): $($_.Status)" -ForegroundColor $color
}
Write-Host ""

if ($failCount -gt 0) {
    exit 1
}
