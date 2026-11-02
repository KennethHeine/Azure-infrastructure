# Offline integration checks. az, gh and sleeps are functions; no provider calls.
param([string]$ScriptPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/create-repo-infrastructure.ps1'))
$ErrorActionPreference = 'Stop'
$env:AUTOMATION_GITHUB_TOKEN = 'synthetic-offline-fixture'

function Assert($condition, [string]$message) {
    if (-not $condition) { throw $message }
}
function Option([object[]]$Arguments, [string]$Name) {
    $index = [Array]::IndexOf($Arguments, $Name)
    if ($index -ge 0) { return $Arguments[$index + 1] }
    return ''
}
function Start-Sleep { param($Seconds) }

function az {
    $global:LASTEXITCODE = 0
    $command = $args -join ' '
    if ($command -like 'account show *') {
        return '{"id":"00000000-0000-0000-0000-000000000001","tenantId":"00000000-0000-0000-0000-000000000002"}'
    }
    if ($command -like 'group show *') { return 'rg-offline-entra' }
    if ($command -like 'group create *') { return '{}' }
    if ($command -like 'ad app list *') {
        if ($command -like '*preview*') { return $global:FakePreviewApp }
        return $global:FakeProdApp
    }
    if ($command -like 'ad sp list *') {
        if ($command -like '*preview*') { return $global:FakePreviewSp }
        return $global:FakeProdSp
    }
    if ($command -like 'ad sp show *') { return $global:FakeGraphSp }
    if ($command -like 'ad app show *') { return '66666666-6666-6666-6666-666666666666' }
    if ($command -like 'role assignment list *') { return 'synthetic-existing-owner' }
    if ($command -like 'ad app federated-credential list *') {
        if ($command -like '*github-actions-main*') { return "$($global:FakePrefix):ref:refs/heads/main" }
        if ($command -like '*github-actions-pr*') { return "$($global:FakePrefix):pull_request" }
    }
    if ($command -like 'rest *') {
        $method = Option $args '--method'; $url = Option $args '--url'
        if ($method -eq 'GET' -and $url -like '*/federatedIdentityCredentials') {
            return (@{value=@(@{
                id='synthetic-preview-fic'; name='github-actions-branches'
                claimsMatchingExpression=@{value=("claims['sub'] matches '{0}:ref:refs/heads/*'" -f $global:FakePrefix)}
            })} | ConvertTo-Json -Depth 5 -Compress)
        }
        if ($url -match '/servicePrincipals/([^/]+)/appRoleAssignments$') {
            $principal = $Matches[1]
            Assert ($principal -in @($global:FakeProdSp, $global:FakePreviewSp)) 'Unexpected Graph target'
            if ($method -eq 'GET') {
                $query = Option $args '--query'
                Assert ($query -match "appRoleId=='([^']+)'") 'Unknown role query'
                if ($global:FakeGrants.Contains("$principal/$($Matches[1])")) { return 'synthetic-existing-grant' }
                return ''
            }
            if ($method -eq 'POST') {
                $body = Option $args '--body' | ConvertFrom-Json
                Assert ($body.principalId -eq $principal -and $body.resourceId -eq $global:FakeGraphSp) 'Grant binding mismatch'
                Assert ($body.appRoleId -in $global:FakeExpectedRoles) 'Unexpected Graph permission'
                Assert ($global:FakeGrants.Add("$principal/$($body.appRoleId)")) 'Duplicate grant POST'
                $global:FakeGrantPosts++
                return '{}'
            }
        }
    }
    throw "Unexpected mocked az operation: $command"
}

function gh {
    Assert $global:FakeGitHubAllowed 'Azure-only lane called GitHub'
    $global:LASTEXITCODE = 0
    $command = $args -join ' '
    if ($command -like 'repo view *') { return '{"name":"offline-entra"}' }
    if ($command -like 'api *actions/oidc/customization/sub*') { return $global:FakePrefix }
    if ($command -like 'api *contents/*') { return '{}' }
    if ($command -like 'api --method PATCH *') { return }
    if ($command -like 'secret set *') { return }
    if ($command -like 'variable set *') {
        $global:FakeVariables[$args[2]] = Option $args '--body'
        return
    }
    throw "Unexpected mocked gh operation: $command"
}

$global:FakeProdApp = '11111111-1111-1111-1111-111111111111'
$global:FakeProdSp = '22222222-2222-2222-2222-222222222222'
$global:FakePreviewApp = '33333333-3333-3333-3333-333333333333'
$global:FakePreviewSp = '44444444-4444-4444-4444-444444444444'
$global:FakeGraphSp = '55555555-5555-5555-5555-555555555555'
$global:FakePrefix = 'repo:OfflineTests/offline-entra'
$global:FakeExpectedRoles = @('18a4783c-866b-4cc7-a460-3d5e5662c884', 'df021288-bdef-4463-88db-98f22de89214')
Assert ((Get-Command az).CommandType -eq 'Function' -and (Get-Command gh).CommandType -eq 'Function') 'Mocks not installed'

$cases = @(
    foreach ($template in @('none', 'container-app')) {
        foreach ($auth in @($false, $true)) {
            foreach ($preview in @($false, $true)) {
                @{ Template=$template; Auth=$auth; Preview=$preview }
            }
        }
    }
    @{ Template='static-web'; Auth=$false; Preview=$false }
    @{ Template='static-web'; Auth=$true; Preview=$false }
    @{ Template='none'; Auth=$false; Preview=$false; AzureOnly=$true }
    @{ Template='none'; Auth=$true; Preview=$false; AzureOnly=$true }
)
foreach ($case in $cases) {
    $global:FakeGrants = [System.Collections.Generic.HashSet[string]]::new()
    $global:FakeGrantPosts = 0
    $global:FakeVariables = @{}
    $global:FakeGitHubAllowed = -not $case.AzureOnly
    $expectedPrincipals = @($global:FakeProdSp)
    if ($case.Preview) { $expectedPrincipals += $global:FakePreviewSp }
    $runArguments = @{
        GitHubRepo='offline-entra'; GitHubOrg='OfflineTests'; Template=$case.Template
        EnableAuth=$case.Auth; Preview=$case.Preview
    }
    $settings = $null
    if ($case.AzureOnly) {
        $settings = New-TemporaryFile
        $runArguments['AzureOnly'] = $true
        $runArguments['OidcSubjectPrefix'] = $global:FakePrefix
        $runArguments['SettingsOutput'] = $settings.FullName
    }
    try {
      foreach ($run in 1..2) {
        & $ScriptPath @runArguments 6>$null | Out-Null
        Assert ($LASTEXITCODE -eq 0) 'Mocked onboarding failed'
        Assert ($global:FakeGrantPosts -eq 2 * $expectedPrincipals.Count) 'Every deployment SP must receive exactly two Graph roles, without duplicate POSTs'
        foreach ($principal in $expectedPrincipals) {
            foreach ($role in $global:FakeExpectedRoles) {
                Assert ($global:FakeGrants.Contains("$principal/$role")) 'Missing mandatory Graph role'
            }
        }
        if ($case.AzureOnly) {
            $export = Get-Content $settings.FullName -Raw | ConvertFrom-Json
            Assert ($export.resourceGroup -eq 'rg-offline-entra' -and $export.clientId -eq $global:FakeProdApp) 'Wrong Azure-only settings export'
            Assert ($global:FakeVariables.Count -eq 0) 'Azure-only changed GitHub variables'
        } elseif ($case.Template -eq 'container-app') {
            Assert ($global:FakeVariables['ENABLE_AUTH'] -ceq $case.Auth.ToString().ToLowerInvariant()) 'Easy Auth setting changed'
        } else {
            Assert (-not $global:FakeVariables.ContainsKey('ENABLE_AUTH')) 'Unexpected Easy Auth variable'
        }
        if (-not $case.AzureOnly) { Assert ($global:FakeVariables['RESOURCE_GROUP'] -eq 'rg-offline-entra') 'Resource group setting changed' }
        if ($case.Preview) { Assert ($global:FakeVariables['RESOURCE_GROUP_PREVIEW'] -eq 'rg-offline-entra-preview') 'Preview isolation setting changed' }
      }
    } finally {
        if ($settings) { Remove-Item $settings.FullName -ErrorAction SilentlyContinue }
    }
    Write-Output "PASS: template=$($case.Template) auth=$($case.Auth) preview=$($case.Preview) AzureOnly=$([bool]$case.AzureOnly); grants and second-run idempotence; Easy Auth preserved"
}
# A partial prior deployment must add only the missing role for each SP.
$global:FakeGrants = [System.Collections.Generic.HashSet[string]]::new()
foreach ($principal in @($global:FakeProdSp, $global:FakePreviewSp)) {
    $null = $global:FakeGrants.Add("$principal/$($global:FakeExpectedRoles[0])")
}
$global:FakeGrantPosts = 0
$global:FakeVariables = @{}
$global:FakeGitHubAllowed = $true
foreach ($run in 1..2) {
    & $ScriptPath -GitHubRepo offline-entra -GitHubOrg OfflineTests -Template none -EnableAuth $false -Preview $true 6>$null | Out-Null
    Assert ($global:FakeGrantPosts -eq 2 -and $global:FakeGrants.Count -eq 4) 'Partial-state repair duplicated or omitted a grant'
}
Write-Output 'PASS: partial prod/preview grants repaired once; no duplicate POST on rerun'
Write-Output "PASS: $($cases.Count) matrix cases + partial-state case / $(($cases.Count + 1) * 2) mocked runs; no real az, gh or provider calls"
