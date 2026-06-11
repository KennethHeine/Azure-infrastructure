# Create Repository Infrastructure
# This script onboards a single repository. It creates:
#   1. A Resource Group (rg-<repo>)
#   2. A Service Principal (sp-<repo>-github)
#   3. Federated credentials for GitHub Actions OIDC (main branch + pull requests)
#   4. Owner role assignment on the new RG for the repo's SP
#   5. GitHub repository (private) with auto-delete head branches enabled
#   6. Azure secrets (AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID)
#   7. Default README.md with infrastructure details
#   8. Agent guide files (AGENTS.md + CLAUDE.md) describing the Azure setup and
#      the convention to build Bicep and deploy via GitHub Actions workflows
#
# The GitHub steps (repo, secrets, README, agent files) require the
# AUTOMATION_GITHUB_TOKEN environment variable.
#
# Fully idempotent — safe to run multiple times.
#
# Usage:
#   .\create-repo-infrastructure.ps1 -GitHubRepo "my-app"
#   .\create-repo-infrastructure.ps1 -GitHubRepo "my-app" -GitHubOrg "MyOrg" -Location "swedencentral"

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GitHubRepo,

    [string]$GitHubOrg = "KennethHeine",

    [string]$Location = "swedencentral",

    # Starter template the new repo is scaffolded from (GitHub template repo).
    #   none          -> empty repo (legacy behaviour)
    #   container-app -> KennethHeine/template-container-app
    #   static-web    -> KennethHeine/template-static-web
    [ValidateSet("none", "container-app", "static-web")]
    [string]$Template = "none",

    # For container-app repos: enable Entra built-in auth by default. Surfaced as
    # a repo variable so the app's Bicep/workflows can read it.
    [bool]$EnableAuth = $true
)

$ErrorActionPreference = "Stop"

# ─── Derive names from repo ──────────────────────────────────────────
$ResourceGroupName = "rg-$GitHubRepo"
$ServicePrincipalName = "sp-$GitHubRepo-github"

# Maps the -Template value to its GitHub template repository.
$templateRepoMap = @{
    "container-app" = "$GitHubOrg/template-container-app"
    "static-web"    = "$GitHubOrg/template-static-web"
}

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Onboard Repository Infrastructure" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "GitHub Repo:       $GitHubOrg/$GitHubRepo"
Write-Host "Resource Group:    $ResourceGroupName"
Write-Host "Location:          $Location"
Write-Host "Service Principal: $ServicePrincipalName"
Write-Host "Template:          $Template"
if ($Template -eq "container-app") { Write-Host "Entra auth:        $EnableAuth" }
Write-Host ""

# ─── Prerequisites ───────────────────────────────────────────────────
try {
    $null = Get-Command az -ErrorAction Stop
} catch {
    Write-Host "Error: Azure CLI is not installed." -ForegroundColor Red
    exit 1
}

Write-Host "Checking Azure CLI authentication..."
try {
    $accountJson = az account show --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Not authenticated" }
    $accountInfo = $accountJson | ConvertFrom-Json
    $subscriptionId = $accountInfo.id
    $tenantId = $accountInfo.tenantId
} catch {
    Write-Host "Error: Not logged in. Run 'az login' first." -ForegroundColor Red
    exit 1
}

Write-Host "  Subscription: $subscriptionId" -ForegroundColor Green
Write-Host "  Tenant:       $tenantId" -ForegroundColor Green
Write-Host ""

# ─── Step 1: Create Resource Group ───────────────────────────────────
Write-Host "Step 1: Creating resource group '$ResourceGroupName' in '$Location'..." -ForegroundColor Cyan

$existingRg = az group show --name $ResourceGroupName --query "name" --output tsv --only-show-errors 2>&1
if ($LASTEXITCODE -eq 0 -and $existingRg -eq $ResourceGroupName) {
    Write-Host "  Resource group already exists" -ForegroundColor Yellow
} else {
    az group create --name $ResourceGroupName --location $Location --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Failed to create resource group" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Resource group created" -ForegroundColor Green
}
Write-Host ""

# ─── Step 2: Create App Registration ─────────────────────────────────
Write-Host "Step 2: Creating app registration '$ServicePrincipalName'..." -ForegroundColor Cyan

$appId = az ad app list --display-name $ServicePrincipalName --query "[0].appId" --output tsv --only-show-errors

if ($appId) {
    Write-Host "  App registration already exists (appId: $appId)" -ForegroundColor Yellow
} else {
    $appId = az ad app create --display-name $ServicePrincipalName --query "appId" --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not $appId) {
        Write-Host "Error: Failed to create app registration" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Created app registration (appId: $appId)" -ForegroundColor Green
    Write-Host "  Waiting for Azure AD replication..." -ForegroundColor Gray
    Start-Sleep -Seconds 15
}
Write-Host ""

# ─── Step 3: Ensure Service Principal exists ─────────────────────────
Write-Host "Step 3: Ensuring service principal exists..." -ForegroundColor Cyan

$spObjectId = az ad sp list --display-name $ServicePrincipalName --query "[?appId=='$appId'].id | [0]" --output tsv --only-show-errors

if (-not $spObjectId) {
    # Retry loop — Azure AD replication can take time after app registration creation
    $maxRetries = 5
    $retryDelay = 10
    $created = $false

    for ($i = 1; $i -le $maxRetries; $i++) {
        az ad sp create --id $appId --only-show-errors 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $created = $true
            break
        }
        Write-Host "  Attempt $i/$maxRetries failed, retrying in ${retryDelay}s..." -ForegroundColor Yellow
        Start-Sleep -Seconds $retryDelay
    }

    if (-not $created) {
        Write-Host "Error: Failed to create service principal after $maxRetries attempts" -ForegroundColor Red
        exit 1
    }

    # Retry loop to retrieve the SP objectId (replication delay)
    for ($j = 1; $j -le 5; $j++) {
        Start-Sleep -Seconds 5
        $spObjectId = az ad sp list --display-name $ServicePrincipalName --query "[?appId=='$appId'].id | [0]" --output tsv --only-show-errors
        if ($spObjectId) { break }
        Write-Host "  Waiting for SP to replicate (attempt $j/5)..." -ForegroundColor Yellow
    }

    if (-not $spObjectId) {
        Write-Host "  WARNING: Could not retrieve SP objectId, proceeding with appId" -ForegroundColor Yellow
    } else {
        Write-Host "  Created service principal (objectId: $spObjectId)" -ForegroundColor Green
    }
} else {
    Write-Host "  Service principal already exists (objectId: $spObjectId)" -ForegroundColor Yellow
}
Write-Host ""

# ─── Step 4: Assign Owner role on the Resource Group ─────────────────
Write-Host "Step 4: Assigning Owner role on resource group '$ResourceGroupName'..." -ForegroundColor Cyan

$rgScope = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName"

$existingRole = az role assignment list `
    --assignee $appId `
    --role "Owner" `
    --scope $rgScope `
    --query "[0].id" --output tsv --only-show-errors 2>&1

if ($existingRole) {
    Write-Host "  Owner role already assigned" -ForegroundColor Yellow
} else {
    # Retry loop — SP may not have replicated to graph yet
    $roleAssigned = $false
    for ($r = 1; $r -le 5; $r++) {
        az role assignment create `
            --assignee $appId `
            --role "Owner" `
            --scope $rgScope --only-show-errors 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $roleAssigned = $true
            break
        }
        Write-Host "  Role assignment attempt $r/5 failed, retrying in 10s..." -ForegroundColor Yellow
        Start-Sleep -Seconds 10
    }
    if (-not $roleAssigned) {
        Write-Host "Error: Failed to assign Owner role after 5 attempts" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Owner role assigned on $ResourceGroupName" -ForegroundColor Green
}
Write-Host ""

# NOTE: container-app repos provision their OWN Azure Container Registry inside
# their own resource group (see template-container-app/infra/main.bicep). The
# repo's SP is Owner of rg-<repo>, so it can create the ACR, push images, and
# grant its Container App's managed identity AcrPull — all within its own RG.
# There is no shared registry and therefore no cross-RG ACR grant to set up here.

# ─── Step 5: Create Federated Credentials ────────────────────────────
Write-Host "Step 5: Creating federated credentials..." -ForegroundColor Cyan

function Add-FederatedCredential {
    param(
        [string]$AppId,
        [string]$Name,
        [string]$Subject,
        [string]$Description
    )

    $existing = az ad app federated-credential list --id $AppId --query "[?name=='$Name'].name" --output tsv --only-show-errors
    if ($existing) {
        Write-Host "  Federated credential '$Name' already exists" -ForegroundColor Yellow
        return
    }

    $credJson = @"
{
    "name": "$Name",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "$Subject",
    "description": "$Description",
    "audiences": ["api://AzureADTokenExchange"]
}
"@

    $tempDir = [System.IO.Path]::GetTempPath()
    $tempFile = Join-Path $tempDir "fc-$Name.json"
    $credJson | Out-File -FilePath $tempFile -Encoding utf8

    az ad app federated-credential create --id $AppId --parameters $tempFile --only-show-errors 2>&1 | Out-Null
    $fcExitCode = $LASTEXITCODE

    Remove-Item -Path $tempFile -ErrorAction SilentlyContinue

    if ($fcExitCode -eq 0) {
        Write-Host "  Created federated credential '$Name'" -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Failed to create federated credential '$Name' (may already exist or replication delay)" -ForegroundColor Yellow
    }

    # Reset LASTEXITCODE so it doesn't leak a stale non-zero value
    $global:LASTEXITCODE = 0
}

# Federated credential for main branch
Add-FederatedCredential `
    -AppId $appId `
    -Name "github-actions-main" `
    -Subject "repo:$GitHubOrg/${GitHubRepo}:ref:refs/heads/main" `
    -Description "GitHub Actions - main branch"

# Federated credential for pull requests
Add-FederatedCredential `
    -AppId $appId `
    -Name "github-actions-pr" `
    -Subject "repo:$GitHubOrg/${GitHubRepo}:pull_request" `
    -Description "GitHub Actions - pull requests"

Write-Host ""

# ─── Step 5b: Grant Graph permission for Entra Easy Auth ─────────────
# Container-app repos with auth create their own Entra "Easy Auth" application
# at deploy time via the Microsoft Graph Bicep extension, running as THIS repo's
# SP. That requires the SP to hold Microsoft Graph Application.ReadWrite.OwnedBy
# (it can then manage only the apps it owns). The central onboarding SP holds
# AppRoleAssignment.ReadWrite.All (see setup-service-principal.ps1), so it can
# grant that app role here. Idempotent.
if ($Template -eq "container-app" -and $EnableAuth) {
    Write-Host "Step 5b: Granting Graph 'Application.ReadWrite.OwnedBy' to the SP (Entra auth)..." -ForegroundColor Cyan

    $graphAppId = "00000003-0000-0000-c000-000000000000"
    $ownedByRoleId = "18a4783c-866b-4cc7-a460-3d5e5662c884"  # Application.ReadWrite.OwnedBy

    if (-not $spObjectId) {
        $spObjectId = az ad sp list --display-name $ServicePrincipalName `
            --query "[?appId=='$appId'].id | [0]" --output tsv --only-show-errors
    }
    $graphSpId = az ad sp show --id $graphAppId --query "id" --output tsv --only-show-errors

    if ($spObjectId -and $graphSpId) {
        $existingGrant = az rest --method GET `
            --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spObjectId/appRoleAssignments" `
            --query "value[?appRoleId=='$ownedByRoleId'] | [0].id" --output tsv --only-show-errors 2>&1
        if ($existingGrant) {
            Write-Host "  Application.ReadWrite.OwnedBy already granted" -ForegroundColor Yellow
        } else {
            $grantBody = "{`"principalId`":`"$spObjectId`",`"resourceId`":`"$graphSpId`",`"appRoleId`":`"$ownedByRoleId`"}"
            az rest --method POST `
                --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spObjectId/appRoleAssignments" `
                --headers "Content-Type=application/json" `
                --body $grantBody --only-show-errors 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Granted Application.ReadWrite.OwnedBy" -ForegroundColor Green
            } else {
                Write-Host "  WARNING: Failed to grant Application.ReadWrite.OwnedBy — Entra auth deploy may fail" -ForegroundColor Yellow
            }
        }
        $global:LASTEXITCODE = 0
    } else {
        Write-Host "  WARNING: Could not resolve SP / Graph object IDs — skipping Graph grant" -ForegroundColor Yellow
    }
    Write-Host ""
}

# ─── Step 6: Create GitHub Repository ────────────────────────────────
Write-Host "Step 6: Creating GitHub repository '$GitHubOrg/$GitHubRepo'..." -ForegroundColor Cyan

$ghToken = $env:AUTOMATION_GITHUB_TOKEN
if (-not $ghToken) {
    Write-Host "  WARNING: AUTOMATION_GITHUB_TOKEN not set — skipping GitHub repo creation, settings, and secrets" -ForegroundColor Yellow
} else {
    # Use GH_TOKEN for all gh CLI calls in this section
    $env:GH_TOKEN = $ghToken

    try {
        $null = Get-Command gh -ErrorAction Stop
    } catch {
        Write-Host "Error: GitHub CLI (gh) is not installed." -ForegroundColor Red
        Write-Host "Install it from: https://cli.github.com"
        exit 1
    }

    $repoFullName = "$GitHubOrg/$GitHubRepo"

    # Check if repo already exists
    $repoView = gh repo view $repoFullName --json name 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Repository '$repoFullName' already exists" -ForegroundColor Yellow
    } elseif ("$repoView" -match 'Could not resolve to a Repository|Not Found') {
        # Repo genuinely doesn't exist yet — create it, optionally scaffolded
        # from a GitHub template repository.
        $createArgs = @($repoFullName, '--private')
        if ($Template -ne 'none') {
            $templateRepo = $templateRepoMap[$Template]
            $createArgs += @('--template', $templateRepo)
            Write-Host "  Scaffolding from template '$templateRepo'" -ForegroundColor Gray
        }
        $createOutput = gh repo create @createArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Error: Failed to create repository '$repoFullName'" -ForegroundColor Red
            Write-Host "  gh: $createOutput" -ForegroundColor Red
            exit 1
        }
        Write-Host "  Created repository '$repoFullName'" -ForegroundColor Green
    } else {
        # A non-"not found" failure on a read call is almost always a bad token
        # (expired, revoked, or missing the 'repo' scope). Surface it clearly
        # instead of misreporting it as a failed repository creation.
        Write-Host "Error: Could not query repository '$repoFullName' — AUTOMATION_GITHUB_TOKEN may be invalid, expired, or lack the 'repo' scope" -ForegroundColor Red
        Write-Host "  gh: $repoView" -ForegroundColor Red
        Write-Host "  Validate it:  ./scripts/test-automation-token.ps1" -ForegroundColor Red
        Write-Host "  Rotate it:    ./scripts/rotate-automation-token.ps1" -ForegroundColor Red
        exit 1
    }
    Write-Host ""

    # ─── Step 7: Repo merge settings ─────────────────────────────────
    # delete_branch_on_merge keeps the repo free of stale Dependabot branches;
    # allow_auto_merge lets the dependabot-auto-merge workflow use
    # `gh pr merge --auto` (the GitHub App token cannot change repo settings,
    # so this must happen here with the automation PAT).
    Write-Host "Step 7: Enabling auto-delete head branches + auto-merge..." -ForegroundColor Cyan

    gh api --method PATCH "repos/$repoFullName" -f delete_branch_on_merge=true -f allow_auto_merge=true --silent 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Auto-delete head branches + auto-merge enabled" -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Failed to update repo merge settings" -ForegroundColor Yellow
    }
    Write-Host ""

    # ─── Step 8: Set Azure secrets on the repo ───────────────────────
    Write-Host "Step 8: Setting Azure secrets on '$repoFullName'..." -ForegroundColor Cyan

    $secrets = @{
        "AZURE_CLIENT_ID"       = $appId
        "AZURE_TENANT_ID"       = $tenantId
        "AZURE_SUBSCRIPTION_ID" = $subscriptionId
    }

    foreach ($secret in $secrets.GetEnumerator()) {
        Write-Host "  Setting $($secret.Key)..." -NoNewline
        $secret.Value | gh secret set $secret.Key --repo $repoFullName 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host " done" -ForegroundColor Green
        } else {
            Write-Host " FAILED" -ForegroundColor Red
            exit 1
        }
    }
    Write-Host ""

    # ─── Step 8b: Set Actions variables the template workflows consume ───
    Write-Host "Step 8b: Setting Actions variables on '$repoFullName'..." -ForegroundColor Cyan

    # Non-secret config the template's deploy workflows read via ${{ vars.* }}.
    # The container-app template provisions and discovers its own ACR (in this
    # repo's RG), so no ACR_* variables are needed here.
    $variables = [ordered]@{
        "RESOURCE_GROUP" = $ResourceGroupName
    }
    if ($Template -eq "container-app") {
        $variables["ENABLE_AUTH"] = "$EnableAuth".ToLower()
    }

    foreach ($v in $variables.GetEnumerator()) {
        Write-Host "  Setting $($v.Key)=$($v.Value)..." -NoNewline
        gh variable set $v.Key --repo $repoFullName --body "$($v.Value)" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host " done" -ForegroundColor Green
        } else {
            Write-Host " WARNING (continuing)" -ForegroundColor Yellow
        }
        $global:LASTEXITCODE = 0
    }
    Write-Host ""

    # ─── Steps 9-10: Seed README + agent guide files ────────────────
    # Skipped for templated repos: the template repository already ships its
    # own README.md, AGENTS.md, and CLAUDE.md (and template copy is async, so
    # seeding here would race the copy). Only empty (-Template none) repos get
    # the generic onboarding docs below.
    if ($Template -ne 'none') {
        Write-Host "Steps 9-10: Skipped (template '$Template' provides its own README/agent files)" -ForegroundColor Yellow
        Write-Host ""
    } else {

    # ─── Step 9: Create default README.md ────────────────────────────
    Write-Host "Step 9: Creating default README.md in '$repoFullName'..." -ForegroundColor Cyan

    $readmeContent = @"
# $GitHubRepo

## Azure Infrastructure

This repository has been automatically onboarded with the following Azure resources:

### Resource Group

| Property | Value |
|----------|-------|
| Name | ``$ResourceGroupName`` |
| Location | ``$Location`` |

### Identity (Service Principal)

| Property | Value |
|----------|-------|
| Name | ``$ServicePrincipalName`` |
| App ID | ``$appId`` |
| Role | Owner on ``$ResourceGroupName`` |

The service principal uses **federated credentials (OIDC)** for passwordless authentication from GitHub Actions.

### GitHub Actions Secrets

The following secrets are already configured in this repository:

| Secret | Description |
|--------|-------------|
| ``AZURE_CLIENT_ID`` | Service principal application ID |
| ``AZURE_TENANT_ID`` | Azure AD tenant ID |
| ``AZURE_SUBSCRIPTION_ID`` | Azure subscription ID |

### Usage

To authenticate with Azure in a GitHub Actions workflow:

``````yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: azure/login@v2
    with:
      client-id: `${{ secrets.AZURE_CLIENT_ID }}
      tenant-id: `${{ secrets.AZURE_TENANT_ID }}
      subscription-id: `${{ secrets.AZURE_SUBSCRIPTION_ID }}
``````
"@

    # Check if README already exists
    $readmeExists = gh api "repos/$repoFullName/contents/README.md" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  README.md already exists — skipping" -ForegroundColor Yellow
    } else {
        $readmeBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($readmeContent))
        $body = @{
            message = "Initial README with Azure infrastructure details"
            content = $readmeBase64
        } | ConvertTo-Json -Compress

        $body | gh api --method PUT "repos/$repoFullName/contents/README.md" --input - --silent 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  README.md created" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: Failed to create README.md" -ForegroundColor Yellow
        }
    }
    Write-Host ""

    # ─── Step 10: Create agent guide files (AGENTS.md + CLAUDE.md) ────
    Write-Host "Step 10: Creating agent guide files in '$repoFullName'..." -ForegroundColor Cyan

    # Creates a file via the GitHub contents API only if it does not already
    # exist, so existing repos are backfilled and existing files are never
    # overwritten. Idempotent — safe to run on every onboarding pass.
    function Set-RepoFileIfMissing {
        param(
            [string]$RepoFullName,
            [string]$Path,
            [string]$Content,
            [string]$CommitMessage
        )

        $exists = gh api "repos/$RepoFullName/contents/$Path" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  $Path already exists — skipping" -ForegroundColor Yellow
            $global:LASTEXITCODE = 0
            return
        }

        $base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Content))
        $body = @{
            message = $CommitMessage
            content = $base64
        } | ConvertTo-Json -Compress

        $body | gh api --method PUT "repos/$RepoFullName/contents/$Path" --input - --silent 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  $Path created" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: Failed to create $Path" -ForegroundColor Yellow
        }

        # Reset LASTEXITCODE so a stale non-zero value doesn't leak out
        $global:LASTEXITCODE = 0
    }

    $agentsContent = @"
# $GitHubRepo — Agent Guide

This file gives AI coding agents (and humans) the context needed to work in this
repository. It was seeded automatically when the repo was onboarded by the
central **Azure-infrastructure** repo.

## Azure infrastructure

This repo has a dedicated, isolated Azure footprint:

| Property | Value |
|----------|-------|
| Resource Group | ``$ResourceGroupName`` |
| Location | ``$Location`` |
| Identity (Service Principal) | ``$ServicePrincipalName`` |
| App ID | ``$appId`` |
| Permissions | **Owner** on ``$ResourceGroupName`` only |

Authentication is **passwordless OIDC** (federated credentials) — no Azure
passwords or client secrets are stored. The service principal can only touch its
own resource group ``$ResourceGroupName``; it has no access to any other
resources in the subscription.

These GitHub Actions secrets are already configured on the repo:

| Secret | Description |
|--------|-------------|
| ``AZURE_CLIENT_ID`` | Service principal application ID |
| ``AZURE_TENANT_ID`` | Azure AD tenant ID |
| ``AZURE_SUBSCRIPTION_ID`` | Azure subscription ID |

## How to build and deploy Azure resources

When this project needs Azure resources, follow this pattern:

1. **Author infrastructure as Bicep.** Put Bicep templates under an ``infra/``
   folder and define every resource declaratively. Do not create resources by
   hand in the portal or with ad-hoc CLI commands.
2. **Scope everything to this repo's resource group** (``$ResourceGroupName``).
   The service principal is Owner there and nowhere else, so deployments must
   target that resource group.
3. **Deploy via GitHub Actions workflows**, never manually — OIDC login followed
   by a Bicep/ARM deploy step.

### Reference deploy workflow

``````yaml
name: Deploy infrastructure

on:
  workflow_dispatch:
  push:
    branches: [main]
    paths: ['infra/**']

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: `${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: `${{ secrets.AZURE_TENANT_ID }}
          subscription-id: `${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - uses: azure/arm-deploy@v2
        with:
          scope: resourcegroup
          resourceGroupName: $ResourceGroupName
          template: ./infra/main.bicep
          deploymentName: deploy-`${{ github.run_number }}
``````

## Conventions for agents

- Prefer **Bicep** over Terraform or raw ARM JSON for this estate.
- Keep deployments **idempotent** and **scoped to ``$ResourceGroupName``**.
- Never introduce stored Azure credentials — always use the existing OIDC secrets.
- Document any new resources you add in this repo's README.
"@

    Set-RepoFileIfMissing `
        -RepoFullName $repoFullName `
        -Path "AGENTS.md" `
        -Content $agentsContent `
        -CommitMessage "Add AGENTS.md with Azure infrastructure and deployment guidance"

    $claudeContent = @"
# $GitHubRepo

See **[AGENTS.md](./AGENTS.md)** for the full agent guide.

It documents this repository's Azure infrastructure (resource group
``$ResourceGroupName``, the OIDC service principal ``$ServicePrincipalName``, and
the configured ``AZURE_*`` secrets) and the convention to build Azure resources
as **Bicep** and deploy them via **GitHub Actions workflows**.
"@

    Set-RepoFileIfMissing `
        -RepoFullName $repoFullName `
        -Path "CLAUDE.md" `
        -Content $claudeContent `
        -CommitMessage "Add CLAUDE.md pointing to AGENTS.md"

    Write-Host ""
    }  # end Steps 9-10 (empty-repo doc seeding)
}

# ─── Summary ─────────────────────────────────────────────────────────
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Onboarding Complete" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Resource Group:  $ResourceGroupName ($Location)" -ForegroundColor Green
Write-Host "SP App ID:       $appId" -ForegroundColor Green
Write-Host "SP Object ID:    $spObjectId" -ForegroundColor Green
Write-Host "Role:            Owner on $ResourceGroupName" -ForegroundColor Green
if ($ghToken) {
    Write-Host "GitHub Repo:     $repoFullName (private, auto-delete enabled)" -ForegroundColor Green
    Write-Host "Secrets:         AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID" -ForegroundColor Green
    Write-Host "Agent files:     AGENTS.md, CLAUDE.md" -ForegroundColor Green
}
Write-Host ""
Write-Host "The SP has Owner role ONLY on resource group '$ResourceGroupName'." -ForegroundColor Cyan
Write-Host "It cannot access resources in other resource groups." -ForegroundColor Cyan
Write-Host ""
