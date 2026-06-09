<#
.SYNOPSIS
    Reconcile Exchange Online configuration from exchange/config.json (DKIM signing).

.DESCRIPTION
    Exchange Online has no ARM/Bicep surface, so this is the equivalent of the DNS
    deploy for the mail tenant: exchange/config.json is the single source of truth,
    and this script projects it into Exchange Online idempotently.

    AUTHENTICATION — no certificate, no stored secret. Exchange Online PowerShell
    cannot consume a GitHub OIDC token directly, but Connect-ExchangeOnline accepts
    an -AccessToken. So we reuse the *same* OIDC service principal the rest of the
    estate uses: the caller is already signed in to Azure (azure/login in CI, or
    `az login` locally), and we mint an Exchange Online token off that identity with
    `az account get-access-token`. The SP carries the Exchange RBAC it needs via the
    Exchange.ManageAsApp app role + the Exchange Administrator directory role, both
    granted in scripts/setup-service-principal.ps1.

    A managed identity and our federated app are both just service principals in
    Entra; the only thing that differs between them is how the EXO module fetches the
    token (IMDS vs MSAL+cert). -AccessToken lets us sidestep both and hand it the
    token our existing OIDC login already entitles us to.

    Reconciliation is ADDITIVE: only domains listed in config.json are touched. A
    domain whose DKIM CNAMEs have not yet propagated cannot be enabled (Exchange
    reports CnameMissing); that is treated as "pending", not an error, so the run is
    green and self-heals on the next run once dns/records.json has propagated.

.PARAMETER ConfigFile
    Path to the Exchange config JSON. Defaults to ./exchange/config.json.

.PARAMETER RequiredModuleVersion
    ExchangeOnlineManagement version to import if already installed. Informational;
    the CI workflow installs the module.
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = "./exchange/config.json"
)

$ErrorActionPreference = "Stop"

# ─── Load config ──────────────────────────────────────────────────────
if (-not (Test-Path $ConfigFile)) {
    Write-Error "Config file not found: $ConfigFile"
    exit 1
}
$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$organization = $config.organization
if (-not $organization) { Write-Error "config.organization is required"; exit 1 }

Write-Host "Organization: $organization" -ForegroundColor Cyan

# ─── Acquire an Exchange Online token from the current Azure login ─────
# Works for both a CI service principal (azure/login OIDC) and a local `az login`.
Write-Host "Acquiring Exchange Online access token via az CLI..." -ForegroundColor Cyan
$token = az account get-access-token --resource https://outlook.office365.com --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $token) {
    Write-Error "Failed to get an Exchange Online token. Are you logged in (az login / azure/login)?"
    exit 1
}

# ─── Connect ──────────────────────────────────────────────────────────
Import-Module ExchangeOnlineManagement -ErrorAction Stop
Connect-ExchangeOnline -AccessToken $token -Organization $organization -ShowBanner:$false -ErrorAction Stop
Write-Host "Connected to Exchange Online." -ForegroundColor Green

$pending = @()
$changed = @()

try {
    # ─── Reconcile DKIM signing ───────────────────────────────────────
    foreach ($d in $config.dkim) {
        $domain = $d.domain
        $want = [bool]$d.enabled

        $cfg = Get-DkimSigningConfig -Identity $domain -ErrorAction SilentlyContinue
        if (-not $cfg) {
            Write-Host "[$domain] no DKIM config — creating (disabled)..." -ForegroundColor Yellow
            # Create disabled first; enabling requires the CNAMEs to resolve.
            New-DkimSigningConfig -DomainName $domain -Enabled $false -ErrorAction Stop | Out-Null
            $cfg = Get-DkimSigningConfig -Identity $domain -ErrorAction Stop
            $changed += "$domain (created)"
        }

        if ([bool]$cfg.Enabled -eq $want) {
            Write-Host "[$domain] DKIM already Enabled=$want (status: $($cfg.Status)) — no change" -ForegroundColor Gray
            continue
        }

        if ($want) {
            # Always *attempt* the enable rather than trusting $cfg.Status: the
            # Status field (e.g. CnameMissing) is cached from Exchange's last
            # periodic check and lags public DNS, whereas Set-DkimSigningConfig
            # forces a fresh live lookup — so this can succeed even when the cached
            # status still reads CnameMissing. A genuine "CNAMEs not visible to
            # Exchange yet" failure is caught below and reported as pending.
            try {
                Set-DkimSigningConfig -Identity $domain -Enabled $true -ErrorAction Stop
                Write-Host "[$domain] DKIM ENABLED" -ForegroundColor Green
                $changed += "$domain (enabled)"
            } catch {
                # Most commonly Exchange can't resolve the selector CNAMEs yet
                # (its validators lag public DNS) — treat as pending, self-heals.
                Write-Host "[$domain] PENDING — Exchange can't resolve the selector CNAMEs yet: $($_.Exception.Message)" -ForegroundColor Yellow
                $pending += $domain
            }
        } else {
            Set-DkimSigningConfig -Identity $domain -Enabled $false -ErrorAction Stop
            Write-Host "[$domain] DKIM DISABLED" -ForegroundColor Green
            $changed += "$domain (disabled)"
        }
    }

    # ─── Summary ──────────────────────────────────────────────────────
    Write-Host "`n===== Final DKIM state =====" -ForegroundColor Cyan
    Get-DkimSigningConfig |
        Where-Object { $config.dkim.domain -contains $_.Domain } |
        Select-Object Domain, Enabled, Status |
        Format-Table -Auto | Out-String -Width 200 | Write-Host

    if ($changed.Count) { Write-Host "Changed: $($changed -join ', ')" -ForegroundColor Green }
    if ($pending.Count) {
        Write-Host "Pending DNS propagation (not yet enabled): $($pending -join ', ')" -ForegroundColor Yellow
        Write-Host "Re-run this workflow once the selector CNAMEs resolve to finish enabling them." -ForegroundColor Yellow
    }
    if (-not $changed.Count -and -not $pending.Count) {
        Write-Host "Exchange Online already matches config.json — nothing to do." -ForegroundColor Green
    }
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}
