# Register Azure Resource Providers from providers.json
#
# Subscription-level resource providers must be registered before any repo can
# deploy resources of that type. (A missing registration surfaces only at deploy
# time as "The subscription is not registered to use namespace '...'", e.g. the
# claude-runner app failed to start ACI sessions until Microsoft.ContainerInstance
# was registered.) This script keeps that registration under code control.
#
# Idempotent — already-registered providers are skipped. Safe to run repeatedly.
# Requires an az login whose identity can register providers on the subscription
# (the onboarding SP is Owner, so it can).
#
# Usage:
#   .\scripts\register-providers.ps1                          # use ./providers.json, wait for completion
#   .\scripts\register-providers.ps1 -ConfigFile other.json   # explicit config path
#   .\scripts\register-providers.ps1 -NoWait                  # fire registrations, don't block

[CmdletBinding()]
param(
    [string]$ConfigFile,
    [switch]$NoWait,
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"

# ─── Resolve config file path ────────────────────────────────────────
if (-not $ConfigFile) {
    $repoRoot = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { Get-Location }
    $ConfigFile = Join-Path $repoRoot "providers.json"
}

if (-not (Test-Path $ConfigFile)) {
    Write-Host "Error: Config file not found: $ConfigFile" -ForegroundColor Red
    exit 1
}

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Register Azure Resource Providers" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Config file: $ConfigFile"

$providers = (Get-Content $ConfigFile -Raw | ConvertFrom-Json).providers
if (-not $providers -or $providers.Count -eq 0) {
    Write-Host "No providers defined in config file. Nothing to do." -ForegroundColor Yellow
    exit 0
}

Write-Host "Providers:   $($providers.Count) to ensure" -ForegroundColor Cyan
Write-Host ""

# ─── Register any that aren't already registered ─────────────────────
$pending = @()   # namespaces we triggered registration for this run

foreach ($ns in $providers) {
    $state = (az provider show --namespace $ns --query registrationState -o tsv 2>$null)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  $ns — could not query (unknown namespace?), skipping" -ForegroundColor Yellow
        continue
    }

    if ($state -eq 'Registered') {
        Write-Host "  $ns — already Registered" -ForegroundColor DarkGray
        continue
    }

    Write-Host "  $ns — $state → registering…" -ForegroundColor Yellow
    az provider register --namespace $ns --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "::error::Failed to trigger registration for $ns"
        exit 1
    }
    $pending += $ns
}

if ($pending.Count -eq 0) {
    Write-Host ""
    Write-Host "All providers already registered. Nothing to wait for." -ForegroundColor Green
    exit 0
}

if ($NoWait) {
    Write-Host ""
    Write-Host "Triggered registration for: $($pending -join ', ')" -ForegroundColor Green
    Write-Host "Not waiting (-NoWait). Registration completes asynchronously." -ForegroundColor Yellow
    exit 0
}

# ─── Wait for the newly-triggered registrations to complete ──────────
Write-Host ""
Write-Host "Waiting for $($pending.Count) registration(s) to complete (timeout ${TimeoutSeconds}s)…"

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$remaining = [System.Collections.Generic.List[string]]::new()
$pending | ForEach-Object { $remaining.Add($_) }

while ($remaining.Count -gt 0 -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    foreach ($ns in @($remaining)) {
        $state = (az provider show --namespace $ns --query registrationState -o tsv 2>$null)
        if ($state -eq 'Registered') {
            Write-Host "  $ns — Registered" -ForegroundColor Green
            $remaining.Remove($ns) | Out-Null
        }
    }
}

if ($remaining.Count -gt 0) {
    # Non-fatal: registration is in flight and will finish on Azure's side;
    # warn so onboarding isn't blocked indefinitely.
    Write-Host "::warning::Still registering after ${TimeoutSeconds}s: $($remaining -join ', '). They will finish asynchronously."
    exit 0
}

Write-Host ""
Write-Host "All triggered providers are now Registered." -ForegroundColor Green
exit 0
