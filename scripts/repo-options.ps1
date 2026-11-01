# Pure configuration resolution, shared by automatic and split onboarding.
function Get-RepoOnboardingOptions {
    param([Parameter(Mandatory)]$Entry)

    $isBare = $Entry -is [string]
    if (-not $isBare) {
        foreach ($field in @('auth', 'preview', 'manageApplications', 'oidcPullRequests')) {
            if ($null -ne $Entry.$field -and $Entry.$field -isnot [bool]) {
                throw "Repo option '$field' must be a JSON boolean"
            }
        }
        if ($Entry.onboarding -and $Entry.onboarding -notin @('automatic', 'azure-only')) {
            throw 'Unknown onboarding mode'
        }
    }
    $name = if ($isBare) { $Entry } else { $Entry.name }
    $template = if (-not $isBare -and $Entry.template) { $Entry.template } else { 'none' }
    $auth = if (-not $isBare -and $null -ne $Entry.auth) { [bool]$Entry.auth } else { $template -eq 'container-app' }
    $preview = -not $isBare -and [bool]$Entry.preview
    $azureOnly = -not $isBare -and $Entry.onboarding -eq 'azure-only'
    $manageApplications = -not $isBare -and [bool]$Entry.manageApplications
    $trustPullRequests = if (-not $isBare -and $null -ne $Entry.oidcPullRequests) { [bool]$Entry.oidcPullRequests } else { -not $azureOnly }

    if ($azureOnly -and ($Entry.template -ne 'none' -or $preview)) {
        throw "Repo '$name': azure-only onboarding requires template none and no preview"
    }
    if (-not $azureOnly -and (-not $trustPullRequests -or $manageApplications)) {
        throw "Repo '$name': explicit OIDC/Graph options currently require azure-only onboarding"
    }

    [PSCustomObject]@{
        Name = $name
        Template = $template
        EnableAuth = $auth
        Preview = $preview
        AzureOnly = $azureOnly
        EnableApplicationManagement = $manageApplications
        TrustPullRequests = $trustPullRequests
    }
}
