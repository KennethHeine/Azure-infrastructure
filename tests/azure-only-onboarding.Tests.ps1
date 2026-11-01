# Offline behavioral checks. All Azure calls and sleeps are mocked; no credentials.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts/repo-options.ps1')
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Must-Throw([scriptblock]$action) {
    $thrown = $false
    try { & $action } catch { $thrown = $true }
    Assert $thrown 'Expected configuration rejection'
}

$bare = Get-RepoOnboardingOptions 'legacy'
Assert (-not $bare.EnableAuth -and $bare.TrustPullRequests -and -not $bare.AzureOnly) 'Bare repo defaults changed'
$container = Get-RepoOnboardingOptions ([PSCustomObject]@{ name='container'; template='container-app' })
Assert $container.EnableAuth 'Container auth default changed'
$static = Get-RepoOnboardingOptions ([PSCustomObject]@{ name='static'; template='static-web' })
Assert (-not $static.EnableAuth) 'Static auth default changed'
$manual = Get-RepoOnboardingOptions ([PSCustomObject]@{ name='catalog'; template='none'; onboarding='azure-only'; manageApplications=$true })
Assert ($manual.AzureOnly -and -not $manual.TrustPullRequests -and $manual.EnableApplicationManagement -and -not $manual.EnableAuth) 'Manual scope defaults wrong'
Must-Throw { Get-RepoOnboardingOptions ([PSCustomObject]@{ name='invalid'; template='container-app'; onboarding='azure-only' }) }
Must-Throw { Get-RepoOnboardingOptions ([PSCustomObject]@{ name='invalid'; onboarding='azure-only'; preview=$true }) }
Must-Throw { Get-RepoOnboardingOptions ([PSCustomObject]@{ name='invalid'; manageApplications=$true }) }
Must-Throw { Get-RepoOnboardingOptions ([PSCustomObject]@{ name='invalid'; oidcPullRequests=$false }) }
Must-Throw { Get-RepoOnboardingOptions ([PSCustomObject]@{ name='invalid'; oidcPullRequests='false' }) }

function Start-Sleep { param($Seconds) }
function gh { throw 'Azure-only onboarding called GitHub' }
function az {
    $command = $args -join ' '
    $global:LASTEXITCODE = 0
    if ($command -eq 'account show --output json --only-show-errors') {
        return '{"id":"00000000-0000-0000-0000-000000000001","tenantId":"00000000-0000-0000-0000-000000000002"}'
    }
    if ($command -like 'group show *') { return 'rg-catalog-test' }
    if ($command -like 'ad app list *') { return '00000000-0000-0000-0000-000000000003' }
    if ($command -like 'ad sp list *' -or $command -like 'ad sp show *') { return '00000000-0000-0000-0000-000000000004' }
    if ($command -like 'role assignment list *') { return 'synthetic-role-id' }
    if ($command -like 'ad app federated-credential list *') {
        $queryIndex = [Array]::IndexOf($args, '--query')
        if ($queryIndex -lt 0) { return (ConvertTo-Json -InputObject @($global:mockFederation.Values) -Compress) }
        $query = $args[$queryIndex + 1]
        foreach ($credential in $global:mockFederation.Values) {
            if ($query.Contains($credential.name)) { return $credential.subject }
        }
        return ''
    }
    if ($command -like 'ad app federated-credential create *') {
        $index = [Array]::IndexOf($args, '--parameters')
        $credential = Get-Content -LiteralPath $args[$index + 1] -Raw | ConvertFrom-Json
        $global:mockFederation[$credential.name] = $credential
        return '{}'
    }
    if ($command -like 'rest --method GET *appRoleAssignments*') {
        foreach ($roleId in $global:mockGrants) {
            if ($command.Contains($roleId) -and -not $global:mockHideGrants) { return 'synthetic-grant-id' }
        }
        return ''
    }
    if ($command -like 'rest --method POST *appRoleAssignments*') {
        $index = [Array]::IndexOf($args, '--body')
        $global:mockGrants += ($args[$index + 1] | ConvertFrom-Json).appRoleId
        return '{}'
    }
    throw "Unexpected Azure operation: $command"
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('onboarding-test-' + [guid]::NewGuid())
New-Item -ItemType Directory $temp | Out-Null
try {
    foreach ($case in @(
        @{ Auth=$false; Management=$false; PR=$false; Roles=0; Trusts=1 },
        @{ Auth=$false; Management=$true; PR=$false; Roles=1; Trusts=1 },
        @{ Auth=$true; Management=$false; PR=$true; Roles=2; Trusts=2 }
    )) {
        $global:mockFederation = @{}
        $global:mockGrants = @()
        $output = Join-Path $temp 'settings.json'
        & (Join-Path $root 'scripts/create-repo-infrastructure.ps1') -GitHubRepo catalog-test -EnableAuth $case.Auth -EnableApplicationManagement $case.Management -TrustPullRequests $case.PR -AzureOnly -OidcSubjectPrefix 'repo:KennethHeine@212775816/catalog-test@123456' -SettingsOutput $output | Out-Null
        Assert ($global:mockGrants.Count -eq $case.Roles) 'Wrong Graph grant set'
        if (-not $case.Auth) { Assert ($global:mockGrants -notcontains 'df021288-bdef-4463-88db-98f22de89214') 'Unexpected user-directory grant' }
        Assert ($global:mockFederation.Count -eq $case.Trusts) 'Wrong OIDC trust set'
        foreach ($credential in $global:mockFederation.Values) {
            Assert ($credential.issuer -eq 'https://token.actions.githubusercontent.com') 'Wrong issuer'
            Assert ($credential.audiences[0] -eq 'api://AzureADTokenExchange') 'Wrong audience'
            Assert ($credential.subject.StartsWith('repo:KennethHeine@212775816/catalog-test@123456:')) 'Lost live ID prefix'
        }
        $settings = Get-Content $output -Raw | ConvertFrom-Json
        Assert ($settings.resourceGroup -eq 'rg-catalog-test' -and $settings.clientId) 'Missing non-secret settings'
    }
    $global:mockFederation['unapproved'] = [PSCustomObject]@{ name='unapproved'; subject='unrelated' }
    Must-Throw { & (Join-Path $root 'scripts/create-repo-infrastructure.ps1') -GitHubRepo catalog-test -EnableAuth $false -TrustPullRequests $false -AzureOnly -OidcSubjectPrefix 'repo:KennethHeine/catalog-test' -SettingsOutput $output }
    $global:mockFederation = @{
        'github-actions-main' = [PSCustomObject]@{ name='github-actions-main'; subject='repo:KennethHeine/catalog-test:ref:refs/heads/main'; issuer='https://invalid.example'; audiences=@('api://AzureADTokenExchange') }
    }
    $global:mockGrants = @()
    Must-Throw { & (Join-Path $root 'scripts/create-repo-infrastructure.ps1') -GitHubRepo catalog-test -EnableAuth $false -EnableApplicationManagement $true -TrustPullRequests $false -AzureOnly -OidcSubjectPrefix 'repo:KennethHeine/catalog-test' -SettingsOutput $output }
    Assert ($global:mockGrants.Count -eq 0) 'Access granted before existing trust validation'
    $global:mockFederation = @{}
    $global:mockGrants = @()
    $global:mockHideGrants = $true
    Must-Throw { & (Join-Path $root 'scripts/create-repo-infrastructure.ps1') -GitHubRepo catalog-test -EnableAuth $false -EnableApplicationManagement $true -TrustPullRequests $false -AzureOnly -OidcSubjectPrefix 'repo:KennethHeine/catalog-test' -SettingsOutput $output }
    $global:mockHideGrants = $false

    # Exercise the real regular reconciler with harmless local dependencies.
    $stage = Join-Path $temp 'reconciler'
    New-Item -ItemType Directory (Join-Path $stage 'scripts') | Out-Null
    foreach ($file in @('process-repos.ps1', 'repo-options.ps1')) {
        Copy-Item (Join-Path $root "scripts/$file") (Join-Path $stage "scripts/$file")
    }
    Set-Content (Join-Path $stage 'scripts/create-repo-infrastructure.ps1') 'throw "Manual repo reached automatic onboarding"'
    Set-Content (Join-Path $stage 'repos.json') '{"repos":[{"name":"catalog-test","template":"none","onboarding":"azure-only"}]}'
    & (Join-Path $stage 'scripts/process-repos.ps1') -ConfigFile (Join-Path $stage 'repos.json')
    Assert ($LASTEXITCODE -eq 0) 'Automatic reconciler did not skip manual repo'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
Write-Output 'PASS: legacy defaults, configuration rejection, scoped Graph grants, exact main/PR trust, no GitHub calls, settings export, refusal of existing extra trust, automatic reconciler skip'
