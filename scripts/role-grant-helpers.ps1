# Shared validation for immutable, environment-bound service-principal grants.
function Assert-RoleGrantContext {
    param($Grant, $Account)

    $hasPin = $null -ne $Grant.PSObject.Properties['principalId']
    if ($Grant.ownerRepo -and -not $hasPin) {
        throw "Owned grant $($Grant.identityName) requires a pinned principalId."
    }
    if (-not $hasPin) { return }
    if ($Grant.identityType -ne 'servicePrincipal') {
        throw 'principalId is only supported for servicePrincipal grants.'
    }
    foreach ($field in @('principalId', 'tenantId', 'subscriptionId')) {
        if ($Grant.$field -notmatch '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z') {
            throw "Pinned grant $($Grant.identityName) requires a UUID $field."
        }
    }
    if ($Grant.tenantId -ne $Account.tenantId -or $Grant.subscriptionId -ne $Account.id) {
        throw "Pinned grant $($Grant.identityName) does not match the active tenant/subscription."
    }
    if ($Grant.scope -eq 'resource' -and
        -not $Grant.scopeResourceId.StartsWith("/subscriptions/$($Account.id)/", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Pinned grant $($Grant.identityName) has a resource scope outside its subscription."
    }
}

function Get-RoleGrantScope {
    param($Grant, [string]$SubscriptionId)

    if ($Grant.scope -eq 'subscription') { return "/subscriptions/$SubscriptionId" }
    if ($Grant.scope -eq 'resource' -and $Grant.scopeResourceId) { return $Grant.scopeResourceId }
    throw "Invalid scope for grant $($Grant.identityName)."
}

function Resolve-RoleGrantServicePrincipal {
    param($Grant)

    # A pinned object ID is authoritative. No display-name lookup or replacement
    # adoption is allowed, even when the principal has since been deleted.
    if ($Grant.principalId) { return $Grant.principalId }

    # Derived ACR grants still use names: request exact equality and require one
    # result. Escape OData quotes; never select an arbitrary prefix match.
    $escapedName = $Grant.identityName.Replace("'", "''")
    $json = az ad sp list --filter "displayName eq '$escapedName'" --query '[].id' --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Could not resolve service principal $($Grant.identityName)." }
    $ids = @($json | ConvertFrom-Json)
    if ($ids.Count -gt 1) { throw "Ambiguous service principal $($Grant.identityName): $($ids.Count) exact matches." }
    if ($ids.Count -eq 0) { return $null }
    return $ids[0]
}
