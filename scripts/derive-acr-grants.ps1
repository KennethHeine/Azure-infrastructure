# Derive the standard shared-ACR grants for every repo in repos.json.
#
# WHY THIS EXISTS
# Every container-app repo needs the same three-ish grants on the estate-wide
# registry acrkscloud, and they are pure boilerplate: the identity names, the
# repository path prefix, and the ABAC condition are all mechanical functions of
# the repo name. Hand-writing them meant ~32 near-identical role-grants.json
# entries, and — worse — a NEW repo silently had no registry access at all until
# someone remembered to add them, so its very first deploy-app failed at the
# push. This script generates them instead, so onboarding a container-app repo
# grants its registry access automatically.
#
# WHY NOT LET THE REPO GRANT ITSELF
# The obvious alternative is to give each repo's SP User Access Administrator
# (or a constrained Role Based Access Control Administrator) on the shared
# registry, and let the repo's own template Bicep create these assignments. That
# breaks the isolation the shared registry depends on. Azure's constrained
# role-assignment delegation can restrict WHICH ROLE is assigned and to WHICH
# PRINCIPAL, but it has no attribute for the ABAC *condition* carried by the new
# assignment — see
# https://learn.microsoft.com/azure/role-based-access-control/conditions-authorization-actions-attributes
# (the available Request attributes are Role definition ID and Principal
# type/ID, and nothing else). So a repo SP allowed to assign "Container Registry
# Repository Contributor" can assign it to ITSELF with no condition at all, i.e.
# unconditioned write+delete over every other repo's images. Plain User Access
# Administrator is strictly worse: it can also assign User Access Administrator.
#
# This estate already learned that the hard way — see CLAUDE.md's registry
# history, era (1): "one shared ACR in rg-shared with a constrained RBAC-Admin
# delegation — abandoned for cross-repo isolation gaps". Deriving here keeps the
# assignments where every other cross-RG grant already lives: created by the
# onboarding SP, which is subscription Owner anyway, so no new privilege is
# introduced anywhere in the estate.
#
# WHAT IT EMITS (per repo, per environment — prod, plus preview if "preview": true)
#   1. sp-<repo>-github  -> Container Registry Repository Contributor,
#      ABAC-conditioned to that environment's '<prefix>/' path. Contributor, not
#      Writer: the deploy-app cleanup job deletes stale manifests, and Writer has
#      no delete DataAction.
#   2. sp-<repo>-github  -> Container Registry Data Importer and Data Reader +
#      Container Registry Tasks Contributor, UNCONDITIONED. Neither role can
#      carry an ABAC condition; they are the control-plane triggers for
#      `az acr import` and `az acr build`, without which those commands fail with
#      errors that look nothing like permission errors. Skipped when the repo
#      sets cloudBuild:false (it builds with docker and only needs to push).
#   3. Each pull identity -> Container Registry Repository Reader, same
#      '<prefix>/' condition.
#
# CONFIGURING A REPO (repos.json, optional "sharedAcr" key)
#   omitted            -> enabled for template "container-app", using the
#                         defaults below; disabled for every other template.
#   false              -> never derive grants for this repo.
#   true               -> enable with the defaults.
#   { ... }            -> enable, with these overrides:
#       pullIdentities : runtime identities that pull images. Default
#                        ["id-<repo>"]. Needed whenever the app's identity is not
#                        named after the repo, because the template derives it
#                        from appName (article-to-speech -> id-articletts), or
#                        when a repo has several (trading-lab, agent).
#       cloudBuild     : default true. false omits grant #2 for repos that build
#                        with docker + `az acr login` instead of `az acr build`.
#
# The output is an array of objects in exactly the role-grants.json grant shape,
# so apply-role-grants.ps1 can concatenate them with the declared grants and
# apply both through one idempotent code path.
#
# Usage:
#   .\scripts\derive-acr-grants.ps1                        # objects
#   .\scripts\derive-acr-grants.ps1 | ConvertTo-Json -Depth 6

[CmdletBinding()]
param(
    [string]$ConfigFile,
    [string]$RegistryName = "acrkscloud",
    [string]$RegistryResourceGroup = "rg-acr",
    [string]$SubscriptionId
)

$ErrorActionPreference = "Stop"

if (-not $ConfigFile) {
    $repoRoot = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { Get-Location }
    $ConfigFile = Join-Path $repoRoot "repos.json"
}
if (-not (Test-Path $ConfigFile)) {
    throw "derive-acr-grants: config file not found: $ConfigFile"
}

if (-not $SubscriptionId) {
    $SubscriptionId = az account show --query id -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $SubscriptionId) {
        throw "derive-acr-grants: could not resolve the current subscription (az login?)"
    }
}

$registryResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$RegistryResourceGroup/providers/Microsoft.ContainerRegistry/registries/$RegistryName"

# The two ABAC condition shapes. Both follow ACR's documented pattern: allow the
# action outright when it is NOT one of the repository data actions, otherwise
# require the requested repository name to start with this repo's prefix. The
# '/' in the prefix is what stops 'agent/' matching 'agent-preview/…'.
$readActions = @(
    "!(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/content/read'})",
    "!(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/metadata/read'})"
)
$writeActions = $readActions + @(
    "!(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/content/write'})",
    "!(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/metadata/write'})",
    "!(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/content/delete'})",
    "!(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/metadata/delete'})"
)

function New-AcrPathCondition {
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [switch]$IncludeWrite
    )
    $actions = if ($IncludeWrite) { $writeActions } else { $readActions }
    "( ( $($actions -join ' AND ') ) OR ( @Request[Microsoft.ContainerRegistry/registries/repositories:name] StringStartsWithIgnoreCase '$Prefix' ) )"
}

$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$derived = [System.Collections.Generic.List[object]]::new()

foreach ($entry in $config.repos) {
    # repos.json entries are either a bare string (no template) or an object.
    if ($entry -is [string]) {
        $name = $entry; $template = 'none'; $sharedAcr = $null; $preview = $false
    }
    else {
        $name = $entry.name; $template = $entry.template; $sharedAcr = $entry.sharedAcr
        $preview = ($entry.preview -eq $true)
    }

    # Enablement: explicit config wins, otherwise container-app repos are in and
    # everything else is out.
    if ($sharedAcr -is [bool]) {
        $enabled = $sharedAcr
        $sharedAcr = $null
    }
    elseif ($null -ne $sharedAcr) { $enabled = $true }
    else { $enabled = ($template -eq 'container-app') }
    if (-not $enabled) { continue }

    # Distinguish "key absent" (use the default) from an explicit empty array
    # (this repo genuinely has no runtime pull identity — e.g. its images are
    # only ever run by Container Apps Jobs declared elsewhere). Testing the value
    # for truthiness would collapse those two cases, and silently deriving a
    # grant for a nonexistent id-<repo> just produces a confusing warning.
    $pullIdentities = if ($sharedAcr -and $null -ne $sharedAcr.pullIdentities) { @($sharedAcr.pullIdentities) } else { @("id-$name") }
    $cloudBuild = if ($sharedAcr -and $null -ne $sharedAcr.cloudBuild) { [bool]$sharedAcr.cloudBuild } else { $true }

    # Prod, plus an isolated preview environment when the repo opted into one.
    # Preview gets its own TOP-LEVEL prefix rather than nesting under the prod
    # one, so the prod condition's StringStartsWithIgnoreCase '<repo>/' can never
    # match a preview path — the same "preview can never touch prod" guarantee
    # the separate preview SP and RG already provide.
    $environments = @(
        [pscustomobject]@{ Prefix = "$name/"; ResourceGroup = "rg-$name"; ServicePrincipal = "sp-$name-github"; Label = 'prod' }
    )
    if ($preview) {
        $environments += [pscustomobject]@{ Prefix = "$name-preview/"; ResourceGroup = "rg-$name-preview"; ServicePrincipal = "sp-$name-preview-github"; Label = 'preview' }
    }

    foreach ($env in $environments) {
        $where = if ($env.Label -eq 'preview') { " (preview environment)" } else { "" }

        $derived.Add([pscustomobject]@{
            comment               = "DERIVED by scripts/derive-acr-grants.ps1 — do not hand-edit. $name CI/deploy SP$($where): push + post-deploy cleanup-delete on the shared ACR, ABAC-conditioned to '$($env.Prefix)' only."
            identityName          = $env.ServicePrincipal
            identityType          = 'servicePrincipal'
            scope                 = 'resource'
            scopeResourceId       = $registryResourceId
            roles                 = @('Container Registry Repository Contributor')
            condition             = (New-AcrPathCondition -Prefix $env.Prefix -IncludeWrite)
            conditionVersion      = '2.0'
        })

        if ($cloudBuild) {
            $derived.Add([pscustomobject]@{
                comment         = "DERIVED by scripts/derive-acr-grants.ps1 — do not hand-edit. $name CI/deploy SP$($where): the two control-plane roles the ABAC data-plane grant cannot cover. Neither supports an ABAC condition. Data Importer and Data Reader is what makes 'az acr import' resolve the registry at all (prime-base-images caching Docker Hub bases); Tasks Contributor is what lets 'az acr build' schedule a quick build. The actual push stays gated by the conditioned Contributor grant above."
                identityName    = $env.ServicePrincipal
                identityType    = 'servicePrincipal'
                scope           = 'resource'
                scopeResourceId = $registryResourceId
                roles           = @('Container Registry Data Importer and Data Reader', 'Container Registry Tasks Contributor')
            })
        }

        foreach ($identity in $pullIdentities) {
            $derived.Add([pscustomobject]@{
                comment               = "DERIVED by scripts/derive-acr-grants.ps1 — do not hand-edit. $name runtime pull identity $identity ($($env.ResourceGroup))$($where): read-only pull from the shared ACR, ABAC-conditioned to '$($env.Prefix)' only."
                identityName          = $identity
                identityResourceGroup = $env.ResourceGroup
                scope                 = 'resource'
                scopeResourceId       = $registryResourceId
                roles                 = @('Container Registry Repository Reader')
                condition             = (New-AcrPathCondition -Prefix $env.Prefix)
                conditionVersion      = '2.0'
            })
        }
    }
}

# Emit the grants one per pipeline object. Do NOT comma-wrap the array to guard
# against single-element unrolling: the caller already collects with @(...), and
# `@(& thisScript)` around a comma-wrapped array yields ONE element (the inner
# array) instead of N grants — which silently made the whole derivation a no-op.
$derived.ToArray()
