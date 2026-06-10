#Requires -Version 7.0
<#
.SYNOPSIS
Creates the claude-runner GitHub App from github-app/manifest.json and uploads
its private key straight into the claude-runner Key Vault.

.DESCRIPTION
GitHub Apps cannot be created by plain REST or Bicep — GitHub's most
code-driven path is the "app manifest flow", which this script drives
end-to-end:

  1. Opens a browser page that POSTs the manifest (versioned in this repo)
     to github.com — you confirm ONCE on github.com.
  2. GitHub redirects back to a localhost listener with a temporary code.
  3. The script exchanges the code for the app id + private key (PEM) and
     uploads the PEM to the Key Vault secret `github-app-private-key`
     (the key only touches disk as a temp file that is deleted immediately).
  4. It prints the two remaining one-tap steps: install the app, and set
     `githubAppId` in claude-runner/infra/main.parameters.json.

Idempotent-ish: re-running creates a NEW app — delete the old one afterwards
(GitHub → Settings → Developer settings → GitHub Apps). Rotating just the key
does not need this script: generate a new key on the app page and upload it
with `az keyvault secret set`.

.NOTES
Prereqs: pwsh 7+, a browser on THIS machine (localhost callback), and az CLI
logged in as someone with Key Vault Secrets Officer on the vault (the
claude-runner Bicep grants that to `adminObjectId`).
#>
param(
  [string]$ManifestPath = (Join-Path $PSScriptRoot '..' 'github-app' 'manifest.json'),
  [string]$ResourceGroup = 'rg-claude-runner',
  [string]$SecretName = 'github-app-private-key',
  [int]$Port = 8765
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web

# ---------------------------------------------------------------------------
# 1. Manifest from the repo + the localhost redirect this script listens on.
# ---------------------------------------------------------------------------
$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$redirect = "http://localhost:$Port/callback"
$manifest | Add-Member -NotePropertyName redirect_url -NotePropertyValue $redirect -Force
$state = [guid]::NewGuid().ToString('N')
$manifestJson = $manifest | ConvertTo-Json -Depth 10

# The manifest flow requires a form POST (a GET link cannot carry it), so we
# open a tiny auto-submitting local page.
$encoded = [System.Web.HttpUtility]::HtmlEncode($manifestJson)
$formHtml = @"
<!doctype html><html><body onload="document.forms[0].submit()">
<p>Submitting the GitHub App manifest &mdash; confirm on github.com&hellip;</p>
<form action="https://github.com/settings/apps/new?state=$state" method="post">
  <input type="hidden" name="manifest" value="$encoded">
  <noscript><button type="submit">Create GitHub App</button></noscript>
</form></body></html>
"@
$tmpHtml = Join-Path ([IO.Path]::GetTempPath()) "github-app-manifest-$state.html"
Set-Content -Path $tmpHtml -Value $formHtml -Encoding utf8

# ---------------------------------------------------------------------------
# 2. Listen for GitHub's redirect carrying the temporary conversion code.
# ---------------------------------------------------------------------------
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Listening on $redirect — opening the browser; confirm the app creation on github.com…"
Start-Process $tmpHtml

$code = $null
try {
  while ($true) {
    $ctx = $listener.GetContext()
    $q = [System.Web.HttpUtility]::ParseQueryString($ctx.Request.Url.Query)
    $isOurs = ($q['code']) -and ($q['state'] -eq $state -or -not $q['state'])
    if ($isOurs) { $code = $q['code'] }
    $msg = if ($isOurs) { 'GitHub App created — you can close this tab and return to the terminal.' } else { 'Waiting for the GitHub redirect…' }
    $buf = [Text.Encoding]::UTF8.GetBytes("<html><body><h2>$msg</h2></body></html>")
    $ctx.Response.ContentType = 'text/html'
    $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
    $ctx.Response.Close()
    if ($code) { break }
  }
}
finally {
  $listener.Stop()
  Remove-Item $tmpHtml -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 3. Exchange the code for the app credentials (no auth required by GitHub).
# ---------------------------------------------------------------------------
$app = Invoke-RestMethod -Method Post `
  -Uri "https://api.github.com/app-manifests/$code/conversions" `
  -Headers @{ Accept = 'application/vnd.github+json' }
Write-Host "Created GitHub App '$($app.slug)' (id $($app.id))."

# ---------------------------------------------------------------------------
# 4. Upload the private key to the claude-runner Key Vault.
# ---------------------------------------------------------------------------
$vault = az keyvault list -g $ResourceGroup --query '[0].name' -o tsv
if (-not $vault) { throw "No Key Vault found in $ResourceGroup — deploy claude-runner infra first." }
$pemFile = Join-Path ([IO.Path]::GetTempPath()) "github-app-$($app.id).pem"
try {
  Set-Content -Path $pemFile -Value $app.pem -Encoding ascii
  az keyvault secret set --vault-name $vault --name $SecretName --file $pemFile --output none
  Write-Host "Private key uploaded to Key Vault '$vault' as secret '$SecretName'."
}
finally {
  Remove-Item $pemFile -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 5. The two steps GitHub keeps interactive, ready to tap.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Remaining one-time steps:'
Write-Host "  1. Install the app on the account (choose All repositories):"
Write-Host "       https://github.com/apps/$($app.slug)/installations/new"
Write-Host "  2. Set githubAppId = '$($app.id)' in claude-runner/infra/main.parameters.json and push to main."
