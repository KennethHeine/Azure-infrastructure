# Revoke explicitly owned, pinned RBAC grants before pruning their declarations
# or deleting identities. No Graph lookup: orphaned assignments remain removable.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9._-]+$')]
    [string]$RepositoryName,
    [string]$ConfigFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'role-grants.json')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'role-grant-helpers.ps1')

$grants = @((Get-Content $ConfigFile -Raw | ConvertFrom-Json).grants | Where-Object { $_.ownerRepo -eq $RepositoryName })
if ($grants.Count -eq 0) { return }
$accountJson = az account show --query '{id:id,tenantId:tenantId}' --output json --only-show-errors
if ($LASTEXITCODE -ne 0 -or -not $accountJson) { throw 'Could not resolve the cleanup tenant/subscription.' }
$account = $accountJson | ConvertFrom-Json
foreach ($grant in $grants) { Assert-RoleGrantContext $grant $account }

foreach ($grant in $grants) {
    $scope = Get-RoleGrantScope $grant $account.id
    foreach ($role in $grant.roles) {
        $roleJson = az role definition list --name $role --subscription $account.id --query '[].id' --output json --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "Could not resolve role '$role'; cleanup stopped." }
        $roleIds = @($roleJson | ConvertFrom-Json)
        if ($roleIds.Count -ne 1) { throw "Expected one definition for '$role'; cleanup stopped." }
        # Raw ARM IDs avoid Graph/name lookups, including after SP deletion.
        $listArgs = @('role', 'assignment', 'list', '--subscription', $account.id,
            '--scope', $scope, '--fill-principal-name', 'false', '--fill-role-definition-name', 'false',
            '--output', 'json', '--only-show-errors')
        $json = az @listArgs
        if ($LASTEXITCODE -ne 0) { throw "Could not list assignments at $scope; cleanup stopped." }
        $matching = @($json | ConvertFrom-Json | Where-Object {
            $_.principalId -eq $grant.principalId -and $_.scope -eq $scope -and $_.roleDefinitionId -eq $roleIds[0]
        })
        foreach ($assignment in $matching) {
            $expectedPrefix = "$scope/providers/Microsoft.Authorization/roleAssignments/"
            if (-not $assignment.id.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                $assignment.id.Substring($expectedPrefix.Length) -notmatch '\A[0-9a-f-]{36}\z') {
                throw 'Unexpected assignment resource ID; cleanup stopped.'
            }
            az role assignment delete --ids $assignment.id --subscription $account.id --only-show-errors | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Could not remove assignment $($assignment.id); cleanup stopped." }
        }
        $after = az @listArgs
        if ($LASTEXITCODE -ne 0) { throw "Could not verify cleanup at $scope." }
        $remaining = @($after | ConvertFrom-Json | Where-Object {
            $_.principalId -eq $grant.principalId -and $_.scope -eq $scope -and $_.roleDefinitionId -eq $roleIds[0]
        })
        if ($remaining.Count) { throw "'$role' still assigned to $($grant.principalId) at $scope." }
        Write-Host "Verified removal of '$role' for $($grant.principalId) at $scope."
    }
}
