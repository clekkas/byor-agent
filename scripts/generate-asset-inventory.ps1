<#
.SYNOPSIS
  Generate knowledge/azure-assets.md: an inventory of every asset used by this project,
  built from live data (az, gh). The agent bundles this file and uses it to answer
  questions about the project.

  Platform facts (registry target, connection name, token audience, ...) are read from the
  variables of the `agent` GitHub Environment, i.e. the copy of the foundation contract.
  Foundation Terraform state and foundation tfvars are never read.

  - Never reads connection secrets (no listsecrets calls).
  - Redacts IDs: every GUID in the output is replaced with <redacted>, and scopes are shown
    as readable paths instead of resource IDs.

.EXAMPLE
  ./scripts/generate-asset-inventory.ps1
#>
[CmdletBinding()]
param(
    [string]$Repo = 'clekkas/byor-agent',
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutFile) { $OutFile = Join-Path $root 'knowledge\azure-assets.md' }

function Invoke-Json {
    $out = & az @args -o json 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $out | ConvertFrom-Json
}

function Get-AgentVar([string]$Name) {
    $v = & gh variable get $Name --repo $Repo --env agent 2>$null
    if ($LASTEXITCODE -eq 0) { $v.Trim() } else { $null }
}

# /subscriptions/<id>/resourceGroups/rg/providers/Microsoft.X/type/name/... -> "rg / type name / ..."
function Format-Scope([string]$Scope) {
    if ($Scope -match '/resourceGroups/([^/]+)(/providers/(.+))?$') {
        $rg = $Matches[1]
        if (-not $Matches[3]) { return "resource group ``$rg``" }
        $parts = $Matches[3].Split('/')
        $segments = for ($i = 1; $i + 1 -lt $parts.Count; $i += 2) { "$($parts[$i]) ``$($parts[$i + 1])``" }
        return ($segments -join ' / ')
    }
    if ($Scope -match '^/subscriptions/[^/]+$') { return 'subscription' }
    $Scope
}

function ConvertTo-MdTable([object[]]$Rows, [string[]]$Columns) {
    if (-not $Rows) { return '_None._' }
    $lines = @(('| ' + ($Columns -join ' | ') + ' |'), ('|' + (($Columns | ForEach-Object { '---' }) -join '|') + '|'))
    foreach ($r in $Rows) {
        $cells = foreach ($c in $Columns) { "$($r.$c)".Replace('|', '\|').Replace("`n", ' ') }
        $lines += '| ' + ($cells -join ' | ') + ' |'
    }
    $lines -join "`n"
}

# ---- Inputs --------------------------------------------------------------------------
$subscriptionId = Get-AgentVar AZURE_SUBSCRIPTION_ID
$resourceGroup = Get-AgentVar AZURE_RESOURCE_GROUP
$account = Get-AgentVar FOUNDRY_ACCOUNT_NAME
$project = Get-AgentVar FOUNDRY_PROJECT_NAME
$missingVars = @{ AZURE_SUBSCRIPTION_ID = $subscriptionId; AZURE_RESOURCE_GROUP = $resourceGroup; FOUNDRY_ACCOUNT_NAME = $account; FOUNDRY_PROJECT_NAME = $project }.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Key
if ($missingVars) { throw "Missing variables in the '$Repo' agent environment: $($missingVars -join ', '). Load the platform contract with scripts/bootstrap-github-oidc.ps1 -ContractFile." }
$location = (& az group show -n $resourceGroup --subscription $subscriptionId --query location -o tsv 2>$null)

$rgId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"
$accountId = "$rgId/providers/Microsoft.CognitiveServices/accounts/$account"
$projectId = "$accountId/projects/$project"
$projectEndpoint = "https://$account.services.ai.azure.com/api/projects/$project"
$agentName = (Select-String -Path (Join-Path $root 'azure.yaml') -Pattern '^\s*name:\s*(\S+)\s*$' | Select-Object -Last 1).Matches[0].Groups[1].Value
$pipelineAppId = Get-AgentVar AGENT_AZURE_CLIENT_ID
$audienceAppId = Get-AgentVar REGISTRY_TOKEN_AUDIENCE
$registryTarget = Get-AgentVar JF_URL
$registryOidc = Get-AgentVar REGISTRY_OIDC_PROVIDER_NAME
$connectionName = Get-AgentVar JFROG_REGISTRY_CONNECTION_NAME
$githubOidc = Get-AgentVar JFROG_GITHUB_OIDC_PROVIDER
$jfrogRepo = Get-AgentVar JFROG_REPO
$stateAccount = Get-AgentVar AGENT_STATE_STORAGE_ACCOUNT
$stateContainer = Get-AgentVar AGENT_STATE_CONTAINER
$stateKey = Get-AgentVar AGENT_STATE_KEY

Write-Host '==> Collecting Azure resources'
$resources = Invoke-Json resource list -g $resourceGroup
$resourceRows = $resources | Sort-Object type, name | ForEach-Object {
    $res = $_
    $origin = switch ($res.tags.purpose) {
        'github-actions-runner' { 'Platform: CI runner (foundation repo)' }
        'terraform-state' { 'Platform: Terraform state (foundation repo)' }
        default {
            if ($res.type -like 'Microsoft.CognitiveServices/*') { 'Platform: Foundry' }
            elseif ($res.name -like 'byor-ci*') { 'Platform: CI runner (foundation repo)' }
            else { 'Other' }
        }
    }
    [pscustomobject]@{ Name = "``$($res.name)``"; Type = $res.type; Region = $res.location; Origin = $origin }
}

$deployments = Invoke-Json cognitiveservices account deployment list -g $resourceGroup -n $account
$deploymentRows = $deployments | ForEach-Object {
    [pscustomobject]@{ Deployment = "``$($_.name)``"; Model = $_.properties.model.name; Version = $_.properties.model.version; SKU = $_.sku.name }
}

# Connection metadata only - never call listsecrets.
$connections = Invoke-Json rest --method get --url "https://management.azure.com$projectId/connections?api-version=2025-06-01"
$connectionRows = $connections.value | ForEach-Object {
    $meta = if ($_.properties.metadata) { ($_.properties.metadata.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ' } else { '' }
    [pscustomobject]@{ Connection = "``$($_.name)``"; Category = $_.properties.category; Target = $_.properties.target; Metadata = $meta }
}

$projectRes = Invoke-Json resource show --ids $projectId --api-version 2025-06-01

Write-Host '==> Collecting agent versions'
$versions = Invoke-Json rest --method get --resource https://ai.azure.com --url "$projectEndpoint/agents/$agentName/versions?api-version=v1"
$versionRows = $versions.data | Sort-Object { [int]$_.version } -Descending | ForEach-Object {
    $envVars = if ($_.definition.environment_variables) { ($_.definition.environment_variables.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ' } else { '(none: echo mode)' }
    [pscustomobject]@{
        Version  = $_.version
        Status   = $_.status
        Created  = [DateTimeOffset]::FromUnixTimeSeconds([long]$_.created_at).UtcDateTime.ToString('yyyy-MM-dd HH:mm') + ' UTC'
        Image    = "``$($_.definition.container_configuration.image)``"
        Resources = "$($_.definition.cpu) CPU / $($_.definition.memory)"
        Env      = $envVars
    }
}
$latest = $versions.data | Sort-Object { [int]$_.version } -Descending | Select-Object -First 1

Write-Host '==> Collecting Entra apps and role assignments'
$appRows = @()
$fedRows = @()
foreach ($pair in @(@{ id = $audienceAppId; purpose = 'Token audience for the JFrog OIDC exchange (Foundry pulls images)'; origin = 'Pre-existing' },
                    @{ id = $pipelineAppId; purpose = 'GitHub Actions agent deploy identity (federated to environment agent, no secret)'; origin = 'Created: bootstrap script' })) {
    if (-not $pair.id) { continue }
    $app = Invoke-Json ad app show --id $pair.id
    if (-not $app) { continue }
    $appRows += [pscustomobject]@{ App = "``$($app.displayName)``"; Purpose = $pair.purpose; Origin = $pair.origin; 'Token version' = "v$($app.api.requestedAccessTokenVersion)" }
    $fics = Invoke-Json ad app federated-credential list --id $pair.id
    foreach ($f in $fics) { $fedRows += [pscustomobject]@{ App = "``$($app.displayName)``"; Credential = "``$($f.name)``"; Subject = "``$($f.subject)``"; Issuer = $f.issuer } }
}

$roleRows = @()
if ($pipelineAppId) {
    $sp = Invoke-Json ad sp show --id $pipelineAppId
    foreach ($ra in (Invoke-Json role assignment list --assignee $sp.id --all)) {
        $roleRows += [pscustomobject]@{ Principal = 'GitHub Actions agent deploy identity'; Role = $ra.roleDefinitionName; Scope = Format-Scope $ra.scope }
    }
}
if ($stateAccount) {
    foreach ($ra in (Invoke-Json role assignment list --scope "$rgId/providers/Microsoft.Storage/storageAccounts/$stateAccount")) {
        if ($ra.principalType -eq 'User') {
            $roleRows += [pscustomobject]@{ Principal = 'Operator (user)'; Role = $ra.roleDefinitionName; Scope = Format-Scope $ra.scope }
        }
    }
}

Write-Host '==> Collecting GitHub details'
$runners = (& gh api "repos/$Repo/actions/runners" | ConvertFrom-Json).runners
$runnerRows = $runners | ForEach-Object {
    [pscustomobject]@{ Runner = "``$($_.name)``"; Status = $_.status; Labels = (($_.labels | ForEach-Object name) -join ', ') }
}
$varNames = (& gh variable list --repo $Repo --env agent --json name | ConvertFrom-Json).name | Sort-Object
$lastRun = (& gh run list --repo $Repo --limit 1 --json displayTitle,conclusion,status,headSha,createdAt | ConvertFrom-Json) | Select-Object -First 1

$jfrogHost = ($registryTarget -replace '^https://', '').TrimEnd('/')

# ---- Render ------------------------------------------------------------------------------
$generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
$md = @"
# Asset inventory: Foundry BYOR hosted agent (JFrog + OIDC)

Generated $generated by ``scripts/generate-asset-inventory.ps1`` from live Azure, GitHub and Terraform data.
IDs (subscription, tenant, object and client IDs) are redacted. Secrets are never collected.

## Summary

- **Project**: a Microsoft Foundry hosted agent (``$agentName``) whose container image is stored in **JFrog Artifactory**, not Azure Container Registry ("bring your own registry").
- **Image pull**: Foundry pulls the image using **OIDC token exchange**. The Foundry project's managed identity exchanges an Entra token for a short-lived JFrog token, so no registry password is stored.
- **Model**: the agent answers with model **``$($latest.definition.environment_variables.AZURE_AI_MODEL_DEPLOYMENT_NAME)``** through the Foundry project endpoint, using its own platform-managed identity.
- **CI/CD**: GitHub Actions builds the image, pushes it to JFrog (GitHub OIDC), and applies Terraform for the hosted agent only. The agent is managed through the Foundry data plane with AzAPI. All authentication uses OIDC; no secrets are stored.
- **Platform ownership**: the Foundry-to-JFrog registry connection, the CI runner and the Terraform state account belong to the foundation (platform) repo. This repo consumes their published contract and never reads foundation Terraform state.
- **Azure location**: resource group ``$resourceGroup``, Foundry in **$location**.

## Foundry

- **Account**: ``$account`` ($location), pre-existing
- **Project**: ``$project``, endpoint ``$projectEndpoint``, identity type: $($projectRes.identity.type)

### Model deployments

$(ConvertTo-MdTable $deploymentRows @('Deployment', 'Model', 'Version', 'SKU'))

### Project connections

$(ConvertTo-MdTable $connectionRows @('Connection', 'Category', 'Target', 'Metadata'))

The ``$connectionName`` connection is managed by **Terraform (AzAPI)** in the **foundation repo**. It stores the OIDC token-exchange settings: Entra app audience, token endpoint ``/access/api/v1/oidc/token``, and JFrog provider name ``$registryOidc``.

### Hosted agent ``$agentName``

- **Latest version**: $($latest.version) ($($latest.status)), protocol: $(($latest.definition.protocol_versions | ForEach-Object { "$($_.protocol) $($_.version)" }) -join ', ')
- **Image**: ``$($latest.definition.container_configuration.image)`` via registry connection ``$($latest.definition.container_configuration.registry_connection_id)``
- **Agent identity**: platform-managed (blueprint ``$($latest.blueprint_reference.blueprint_id)``); it can call project models by default.

$(ConvertTo-MdTable $versionRows @('Version', 'Status', 'Created', 'Image', 'Resources', 'Env'))

## Azure resources in ``$resourceGroup``

$(ConvertTo-MdTable $resourceRows @('Name', 'Type', 'Region', 'Origin'))

### Terraform state

- **Hosted agent** (``infra/hosted-agent``): remote state in storage account ``$stateAccount``, its own container ``$stateContainer``, key ``$stateKey``. Entra auth only. Public network access is **disabled by subscription policy**, so state is reachable only through the private endpoint from the platform-owned runner VNet. It imports the existing logical agent, preserves Foundry version history, and prevents destroy.
- **Foundation state** (registry connection, runner): owned by the foundation repo, in a different container. This project's identity has no access to it.

## Microsoft Entra ID

$(ConvertTo-MdTable $appRows @('App', 'Purpose', 'Origin', 'Token version'))

### Federated credentials

$(ConvertTo-MdTable $fedRows @('App', 'Credential', 'Subject', 'Issuer'))

The repo uses GitHub's ID-based ("immutable") OIDC subjects, so the credential containing ``@`` IDs is the one in use.

### Role assignments

$(ConvertTo-MdTable $roleRows @('Principal', 'Role', 'Scope'))

## JFrog Artifactory

- **Instance**: ``$registryTarget``
- **Repositories**: ``$jfrogRepo`` (from the platform contract; image path ``$jfrogHost/$jfrogRepo/agent``)
- **Image tags**: CI pushes ``agent:sha-<commit>``. Tags ``0.1`` and ``0.2`` were pushed by hand during setup.
- **OIDC integrations**:

| Integration | Used by | Trusts | Access |
|---|---|---|---|
| ``$registryOidc`` | Foundry (image pull) | Entra tenant (Azure provider), audience = the token-audience Entra app; identity mapping on the project managed identity (``oid``) | Read-only on ``$jfrogRepo`` |
| ``$githubOidc`` | GitHub Actions build job (image push) | ``https://token.actions.githubusercontent.com``, organization ``$($Repo.Split('/')[0])``; mapping ``repository=$Repo``, ``ref=refs/heads/main`` | Read + Deploy on ``$jfrogRepo-local`` |

## GitHub (``$Repo``)

- **Workflow**: ``.github/workflows/deploy-agent.yml``. ``build`` runs on ubuntu-latest; ``deploy`` runs on the self-hosted runner. It triggers on pushes to ``main`` and on manual dispatch, with optional ``image_tag``.
- **Last run**: "$($lastRun.displayTitle)": $($lastRun.status)/$($lastRun.conclusion) at commit ``$("$($lastRun.headSha)".Substring(0, [Math]::Min(7, "$($lastRun.headSha)".Length)))``

### Self-hosted runners

$(ConvertTo-MdTable $runnerRows @('Runner', 'Status', 'Labels'))

### Agent environment variables

$(($varNames | ForEach-Object { "``$_``" }) -join ', ')

## Repository layout

| Path | Purpose |
|---|---|
| ``app.py`` | FastAPI Responses-protocol agent (echo or model mode); serves ``/responses``, ``/readiness``, ``/liveness`` |
| ``azure.yaml`` | Legacy azd compatibility/reference definition; not the CI/CD source of truth |
| ``infra/hosted-agent/`` | Terraform (AzAPI data plane) for the logical hosted agent and versions |
| ``scripts/bootstrap-github-oidc.ps1`` | Agent Entra app, environment-scoped federated credential, agent-state RBAC, ``agent`` GitHub Environment |
| ``scripts/generate-asset-inventory.ps1`` | Generates this file |
| ``knowledge/`` | Knowledge files bundled into the agent image |
"@

# Redact every GUID (subscription, tenant, object, client IDs) and GitHub numeric owner/repo IDs in OIDC subjects.
$md = [regex]::Replace($md, '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', '<redacted>')
$md = [regex]::Replace($md, '(repo:[^@\s`]+)@\d+/([^@\s`]+)@\d+', '$1@<id>/$2@<id>')

New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
Set-Content -Path $OutFile -Value $md -Encoding utf8
Write-Host "==> Wrote $OutFile ($([Math]::Round((Get-Item $OutFile).Length / 1KB, 1)) KB)"
