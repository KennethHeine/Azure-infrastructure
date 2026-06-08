# Test / validate the GitHub automation token (AUTOMATION_GITHUB_TOKEN)
#
# The onboarding workflow uses AUTOMATION_GITHUB_TOKEN (via the gh CLI) to create
# repositories, set Actions secrets, and seed files. If that token is missing,
# expired, revoked, or under-scoped, every gh call in Step 6+ of
# create-repo-infrastructure.ps1 fails with a generic "Failed to create
# repository" error that hides the real cause. This script validates the token
# up front and reports exactly what is wrong.
#
# It checks that the token:
#   1. Is present
#   2. Authenticates (resolves to a GitHub user)
#   3. Is not expiring imminently (reports the expiry date when the token has one)
#   4. Carries the 'repo' scope (classic PAT) — required to create repos and set
#      secrets. Fine-grained tokens don't expose scopes via headers, so the check
#      falls back to a functional write-permission probe against the org.
#
# Exit codes:
#   0  token is valid and usable
#   1  token is missing, invalid, expired, or under-scoped
#
# Usage:
#   $env:AUTOMATION_GITHUB_TOKEN = '<token>'; .\scripts\test-automation-token.ps1
#   .\scripts\test-automation-token.ps1 -Token '<token>'
#   .\scripts\test-automation-token.ps1 -Org KennethHeine   # functional access probe
#   .\scripts\test-automation-token.ps1 -Quiet              # minimal output, exit code only

[CmdletBinding()]
param(
    [string]$Token = $env:AUTOMATION_GITHUB_TOKEN,

    # Org/user the token must be able to administer (for the fine-grained probe).
    [string]$Org = "KennethHeine",

    # Warn if the token expires within this many days.
    [int]$ExpiryWarningDays = 7,

    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

function Write-Step($msg)  { if (-not $Quiet) { Write-Host $msg -ForegroundColor Cyan } }
function Write-Ok($msg)    { if (-not $Quiet) { Write-Host "  $msg" -ForegroundColor Green } }
function Write-Warn($msg)  { if (-not $Quiet) { Write-Host "  $msg" -ForegroundColor Yellow } }
function Write-Err($msg)   { Write-Host "  $msg" -ForegroundColor Red }

# In GitHub Actions, emit a workflow error annotation so the failure is obvious
# at the top of the run instead of buried in step logs.
function Write-CiError($msg) {
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::error::$msg" }
}

Write-Step "Validating AUTOMATION_GITHUB_TOKEN..."

# 1. Present?
if (-not $Token) {
    Write-CiError "AUTOMATION_GITHUB_TOKEN is not set."
    Write-Err "Token is missing. Set AUTOMATION_GITHUB_TOKEN (repo secret) or pass -Token."
    Write-Err "Rotate it with: .\scripts\rotate-automation-token.ps1"
    exit 1
}

# gh CLI required
try {
    $null = Get-Command gh -ErrorAction Stop
} catch {
    Write-CiError "GitHub CLI (gh) is not installed."
    Write-Err "GitHub CLI (gh) is not installed. Install it from https://cli.github.com"
    exit 1
}

# Use the token under test for the validation calls. Save/restore any existing
# GH_TOKEN so we don't clobber the caller's ambient auth.
$prevGhToken = $env:GH_TOKEN
$env:GH_TOKEN = $Token

try {
    # 2. Authenticate and capture response headers (-i) for scopes + expiry.
    $response = gh api user -i 2>&1
    $authExit = $LASTEXITCODE
    $responseText = ($response | Out-String)

    if ($authExit -ne 0) {
        Write-CiError "AUTOMATION_GITHUB_TOKEN is invalid or expired (gh api user failed)."
        Write-Err "Token failed authentication. gh output:"
        Write-Err ($responseText.Trim())
        Write-Err "Rotate it with: .\scripts\rotate-automation-token.ps1"
        exit 1
    }

    $login = if ($responseText -match '"login"\s*:\s*"([^"]+)"') { $Matches[1] } else { "<unknown>" }
    Write-Ok "Authenticated as '$login'"

    # 3. Expiry — present for tokens that expire (classic-with-expiry, fine-grained).
    if ($responseText -match '(?im)^github-authentication-token-expiration:\s*(.+)$') {
        $expiryRaw = $Matches[1].Trim()
        try {
            $expiry = [datetimeoffset]::Parse($expiryRaw)
            $daysLeft = [math]::Floor(($expiry - [datetimeoffset]::UtcNow).TotalDays)
            if ($daysLeft -lt 0) {
                # Auth succeeded, so this is unlikely — but report it explicitly.
                Write-CiError "AUTOMATION_GITHUB_TOKEN expired on $expiryRaw."
                Write-Err "Token expired on $expiryRaw. Rotate it with: .\scripts\rotate-automation-token.ps1"
                exit 1
            } elseif ($daysLeft -le $ExpiryWarningDays) {
                Write-Warn "Token expires in $daysLeft day(s) (on $expiryRaw) — rotate it soon."
            } else {
                Write-Ok "Token valid until $expiryRaw ($daysLeft days left)"
            }
        } catch {
            Write-Warn "Token has an expiry header but it could not be parsed: '$expiryRaw'"
        }
    } else {
        Write-Ok "Token has no expiration (non-expiring PAT)"
    }

    # 4. Scope check. Classic PATs expose scopes via the X-OAuth-Scopes header.
    if ($responseText -match '(?im)^x-oauth-scopes:\s*(.*)$') {
        $scopes = $Matches[1].Trim()
        $scopeList = @($scopes -split ',\s*' | Where-Object { $_ })
        if ($scopeList -contains 'repo') {
            Write-Ok "Token has required 'repo' scope (scopes: $scopes)"
        } else {
            Write-CiError "AUTOMATION_GITHUB_TOKEN is missing the 'repo' scope (has: $scopes)."
            Write-Err "Token lacks the 'repo' scope, which is required to create repositories and set secrets."
            Write-Err "Current scopes: $scopes"
            Write-Err "Rotate it with: .\scripts\rotate-automation-token.ps1"
            exit 1
        }
    } else {
        # No X-OAuth-Scopes header => fine-grained token (or a GitHub App token).
        # Scopes can't be read from headers, so functionally probe administrative
        # access to the org by listing repos we can administer.
        Write-Warn "No classic scopes header (fine-grained token) — running a functional access probe"
        $probe = gh api "users/$Org" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-CiError "AUTOMATION_GITHUB_TOKEN cannot access '$Org' (fine-grained token may lack permissions)."
            Write-Err "Functional probe failed for '$Org'. gh output:"
            Write-Err (($probe | Out-String).Trim())
            exit 1
        }
        Write-Ok "Fine-grained token can reach '$Org' — verify it grants Administration + Secrets read/write on the target repos"
    }

    Write-Step "AUTOMATION_GITHUB_TOKEN is valid."
    exit 0
}
finally {
    # Restore caller's ambient GH_TOKEN.
    if ($null -eq $prevGhToken) {
        Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue
    } else {
        $env:GH_TOKEN = $prevGhToken
    }
}
