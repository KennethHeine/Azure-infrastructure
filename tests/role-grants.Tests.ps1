# Offline integration checks: every az operation is a function; no credentials
# or provider calls. Run with pwsh -NoProfile -File tests/role-grants.Tests.ps1.
param([string]$SourceRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$root = $SourceRoot
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("role-grants-tests-" + [guid]::NewGuid())
$null = New-Item -ItemType Directory $fixture
foreach ($name in @('apply-role-grants.ps1', 'remove-owned-role-grants.ps1', 'role-grant-helpers.ps1')) {
    Copy-Item (Join-Path $root "scripts/$name") $fixture
}
$configPath = Join-Path $fixture 'role-grants.json'
$sub = '00000000-0000-0000-0000-000000000001'
$tenant = '00000000-0000-0000-0000-000000000002'
$runtime = '00000000-0000-0000-0000-000000000003'
$deployer = '00000000-0000-0000-0000-000000000004'
$scope = "/subscriptions/$sub"
$roleId = "$scope/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
$assignmentId = "$scope/providers/Microsoft.Authorization/roleAssignments/00000000-0000-0000-0000-000000000005"
$passes = 0

function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Option([object[]]$Arguments, [string]$Name) {
    $index = [Array]::IndexOf($Arguments, $Name)
    if ($index -ge 0) { return $Arguments[$index + 1] }
    return ''
}
function New-Grant {
    [pscustomobject]@{ identityName='sp-offline-runtime'; identityType='servicePrincipal';
        principalId=$runtime; tenantId=$tenant; subscriptionId=$sub; ownerRepo='offline';
        scope='subscription'; roles=@('Reader') }
}
function New-Assignment([string]$Id=$assignmentId, [string]$Principal=$runtime, [string]$Scope=$scope, [string]$Role=$roleId) {
    [pscustomobject]@{id=$Id; principalId=$Principal; scope=$Scope; roleDefinitionId=$Role}
}
function Reset-Fake {
    $global:FakeAccount = @{id=$sub; tenantId=$tenant}
    $global:FakePrincipals = @()
    $global:FakeAssignments = @()
    $global:FakeCalls = [Collections.Generic.List[string]]::new()
    $global:FakeCreates = [Collections.Generic.List[object]]::new()
    $global:FakeDeletes = [Collections.Generic.List[string]]::new()
    $global:FakeFailure = ''
    $global:FakeStaleReadback = $false
    $global:LASTEXITCODE = 0
}
function az {
    $global:LASTEXITCODE = 0
    $command = $args -join ' '
    $global:FakeCalls.Add($command)
    if ($command -like 'account show *') { return ($global:FakeAccount | ConvertTo-Json -Compress) }
    if ($command -like 'ad sp list *') {
        Assert (-not (Option $args '--display-name')) 'Prefix lookup must never be used'
        $filter = Option $args '--filter'
        Assert ($filter -match "\AdisplayName eq '((?:[^']|'')*)'\z") 'Expected escaped exact OData equality'
        $name = $Matches[1].Replace("''", "'")
        if ($global:FakeFailure -eq 'lookup') { $global:LASTEXITCODE=1; return '[]' }
        $ids = @($global:FakePrincipals | Where-Object { $_.displayName -eq $name } | ForEach-Object { $_.id })
        return (ConvertTo-Json -InputObject $ids -Compress)
    }
    if ($command -like 'identity show *') { return $runtime }
    if ($command -like 'role definition list *') {
        if ($global:FakeFailure -eq 'definition') { $global:LASTEXITCODE=1; return '[]' }
        Assert ((Option $args '--name') -eq 'Reader') 'Unexpected cleanup role'
        return (ConvertTo-Json -InputObject @($roleId) -Compress)
    }
    if ($command -like 'role assignment list *') {
        Assert ((Option $args '--fill-principal-name') -eq 'false') 'Assignment reads must avoid Graph name lookup'
        if ($global:FakeFailure -eq 'list') { $global:LASTEXITCODE=1; return '[]' }
        if (Option $args '--assignee') {
            $assignee = Option $args '--assignee'
            $requestedScope = Option $args '--scope'
            $found = @($global:FakeAssignments | Where-Object {
                $_.principalId -eq $assignee -and $_.scope -eq $requestedScope
            })
            if ($found.Count) { return $found[0].id }
            return ''
        }
        Assert ((Option $args '--fill-role-definition-name') -eq 'false') 'Cleanup must use raw role IDs'
        return (ConvertTo-Json -InputObject @($global:FakeAssignments) -Compress)
    }
    if ($command -like 'role assignment create *') {
        $global:FakeCreates.Add(@($args))
        $global:FakeAssignments += New-Assignment -Principal (Option $args '--assignee-object-id') -Scope (Option $args '--scope')
        return '{}'
    }
    if ($command -like 'role assignment delete *') {
        Assert (-not (Option $args '--assignee')) 'Delete must bind the exact assignment resource ID'
        $id = Option $args '--ids'
        $global:FakeDeletes.Add($id)
        if ($global:FakeFailure -eq 'delete') { $global:LASTEXITCODE=1; return }
        if (-not $global:FakeStaleReadback) {
            $global:FakeAssignments = @($global:FakeAssignments | Where-Object { $_.id -ne $id })
        }
        return
    }
    throw "Unexpected mocked az operation: $command"
}
function Write-Grants($Grants) {
    @{grants=@($Grants)} | ConvertTo-Json -Depth 8 | Set-Content $configPath
}
function Apply-Grants($Grants, [string]$RepositoryName) {
    Write-Grants $Grants
    $options = @{ConfigFile=$configPath}
    if ($RepositoryName) { $options.RepositoryName=$RepositoryName }
    & (Join-Path $fixture 'apply-role-grants.ps1') @options 6>$null | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Application failed'
}
function Remove-Grants($Grants, [string]$RepositoryName='offline') {
    Write-Grants $Grants
    & (Join-Path $fixture 'remove-owned-role-grants.ps1') -ConfigFile $configPath -RepositoryName $RepositoryName 6>$null | Out-Null
}
function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    $caught = $false
    try { & $Action } catch {
        Assert ($_.Exception.Message -match $Pattern) "Unexpected failure: $_"
        $caught = $true
    }
    Assert $caught "Expected failure matching $Pattern"
}
function Pass([string]$Message) { $script:passes++; Write-Output "PASS: $Message" }

try {
    Reset-Fake
    Assert ((Get-Command az).CommandType -eq 'Function') 'CLI mock is required'
    $global:FakePrincipals = @(@{displayName='sp-offline-runtime';id=$deployer})
    Apply-Grants (New-Grant)
    Assert ($global:FakeCreates.Count -eq 1) 'Pinned runtime grant missing'
    Assert ((Option $global:FakeCreates[0] '--assignee-object-id') -eq $runtime) 'Wrong runtime principal'
    Assert ((Option $global:FakeCreates[0] '--scope') -eq $scope) 'Wrong runtime scope'
    Assert (-not @($global:FakeCalls | Where-Object { $_ -like 'ad *' }).Count) 'Pinned grants must not perform Graph/name lookups'
    Apply-Grants (New-Grant)
    Assert ($global:FakeCreates.Count -eq 1) 'Second apply duplicated an existing grant'
    Pass 'pinned runtime target wins over misleading names; existing assignment is reused'

    foreach ($field in @('tenantId','subscriptionId','principalId')) {
        Reset-Fake; $grant=New-Grant
        $grant.$field = if ($field -eq 'principalId') { 'invalid' } else { '00000000-0000-0000-0000-000000000099' }
        Expect-Failure { Apply-Grants $grant } 'UUID|active tenant/subscription'
        Assert ($global:FakeCreates.Count -eq 0) 'Invalid pin/context created a role'
    }
    Reset-Fake; $grant=New-Grant; $grant.PSObject.Properties.Remove('principalId')
    Expect-Failure { Apply-Grants $grant } 'requires a pinned principalId'
    Pass 'wrong tenant, wrong subscription, malformed pin and missing owned pin fail before writes'

    $legacy = [pscustomobject]@{identityName='sp-offline-github';identityType='servicePrincipal';scope='subscription';roles=@('Reader')}
    Reset-Fake
    $global:FakePrincipals = @(@{displayName='sp-offline-github-extra';id=$deployer})
    Apply-Grants $legacy
    Assert ($global:FakeCreates.Count -eq 0) 'Prefix-only collision received a grant'
    $global:FakePrincipals += @{displayName='sp-offline-github';id=$runtime}
    Apply-Grants $legacy
    Assert ((Option $global:FakeCreates[0] '--assignee-object-id') -eq $runtime) 'Exact legitimate SP not selected'
    $global:FakePrincipals += @{displayName='sp-offline-github';id=$deployer}
    Expect-Failure { Apply-Grants $legacy } 'Ambiguous service principal'
    Assert ($global:FakeCreates.Count -eq 1) 'Ambiguous exact names created a role'
    Reset-Fake; $global:FakeFailure='lookup'
    Expect-Failure { Apply-Grants $legacy } 'Could not resolve service principal'
    Assert ($global:FakeCreates.Count -eq 0) 'Lookup failure created a role'
    Pass 'prefix collision rejected; one exact match works; duplicates and lookup failures stop'

    Reset-Fake; $quoted=$legacy.PSObject.Copy(); $quoted.identityName="sp-offline'o"
    $global:FakePrincipals=@(@{displayName=$quoted.identityName;id=$runtime})
    Apply-Grants $quoted
    Assert ($global:FakeCreates.Count -eq 1) 'Escaped OData name failed'
    Reset-Fake; $global:FakeFailure='list'
    Expect-Failure { Apply-Grants (New-Grant) } 'Could not inspect'
    Assert ($global:FakeCreates.Count -eq 0) 'Failed assignment read must never create'
    Pass 'quoted names are escaped; assignment-read errors cannot become writes'

    Reset-Fake
    $managed=[pscustomobject]@{identityName='id-offline';identityResourceGroup='rg-offline';scope='resource';scopeResourceId="$scope/resourceGroups/rg-acr/providers/Microsoft.ContainerRegistry/registries/test";roles=@('Reader');condition='synthetic-condition';conditionVersion='2.0'}
    Apply-Grants $managed
    Assert ((Option $global:FakeCreates[0] '--condition') -eq $managed.condition) 'ABAC condition lost'
    Assert ((Option $global:FakeCreates[0] '--condition-version') -eq '2.0') 'ABAC version lost'
    Reset-Fake; Apply-Grants (New-Grant) -RepositoryName 'offline'
    Assert ($global:FakeCreates.Count -eq 0) 'Azure-only registry filter unexpectedly included runtime access'
    Pass 'managed-identity ABAC behavior and registry-only repository filter are preserved'

    Reset-Fake
    $unrelated=@(
        (New-Assignment -Id "$scope/providers/Microsoft.Authorization/roleAssignments/00000000-0000-0000-0000-000000000006" -Principal $deployer),
        (New-Assignment -Id "$scope/resourceGroups/other/providers/Microsoft.Authorization/roleAssignments/00000000-0000-0000-0000-000000000007" -Scope "$scope/resourceGroups/other"),
        (New-Assignment -Id "$scope/providers/Microsoft.Authorization/roleAssignments/00000000-0000-0000-0000-000000000008" -Role "$scope/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000009")
    )
    $global:FakeAssignments=@((New-Assignment))+$unrelated
    Remove-Grants (New-Grant)
    Assert ($global:FakeDeletes.Count -eq 1 -and $global:FakeDeletes[0] -eq $assignmentId) 'Cleanup touched an unrelated assignment'
    Assert ($global:FakeAssignments.Count -eq 3) 'Cleanup did not preserve unrelated access'
    Remove-Grants (New-Grant)
    Assert ($global:FakeDeletes.Count -eq 1) 'Cleanup rerun duplicated deletion'
    Assert (-not @($global:FakeCalls | Where-Object { $_ -like 'ad *' }).Count) 'Cleanup must work after identity deletion'
    Pass 'cleanup removes only exact principal/role/scope; preserves unrelated access; orphan and rerun safe'

    foreach ($failure in @('definition','list','delete')) {
        Reset-Fake; $global:FakeAssignments=@((New-Assignment)); $global:FakeFailure=$failure
        Expect-Failure { Remove-Grants (New-Grant) } 'cleanup stopped'
    }
    Reset-Fake; $global:FakeAssignments=@((New-Assignment)); $global:FakeStaleReadback=$true
    Expect-Failure { Remove-Grants (New-Grant) } 'still assigned'
    Reset-Fake; $global:FakeAccount.tenantId='00000000-0000-0000-0000-000000000099'
    Expect-Failure { Remove-Grants (New-Grant) } 'active tenant/subscription'
    Assert ($global:FakeDeletes.Count -eq 0) 'Wrong-tenant cleanup deleted assignments'
    Reset-Fake; Remove-Grants (New-Grant) -RepositoryName 'offline-extra'
    Assert ($global:FakeCalls.Count -eq 0) 'Repository prefix collision selected another repo grant'
    Pass 'cleanup errors and stale readback fail; wrong tenant and unrelated owners cannot delete'

    # Exercise the actual ACR derivation with synthetic repo configuration.
    $reposPath=Join-Path $fixture 'repos.json'
    @{repos=@(@{name='offline';template='container-app';preview=$true})} | ConvertTo-Json -Depth 5 | Set-Content $reposPath
    $derived=@(& (Join-Path $root 'scripts/derive-acr-grants.ps1') -ConfigFile $reposPath -SubscriptionId $sub)
    Assert ($derived.Count -eq 6) 'Prod/preview ACR derivation changed'
    Assert (@($derived | Where-Object {$_.identityName -eq 'sp-offline-github'}).Count -eq 2) 'Prod deployment grants missing'
    Assert (@($derived | Where-Object {$_.identityName -eq 'sp-offline-preview-github'}).Count -eq 2) 'Preview deployment grants missing'
    Pass 'existing prod/preview ACR derivation retains all six declarations'
    Write-Output "PASS: $passes groups of offline role-grant regression checks"
} finally {
    Remove-Item $fixture -Recurse -Force
}
