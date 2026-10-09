<#
.SYNOPSIS
  Generate knowledge/azure-assets.md: an inventory of every asset used by this project,
  built from live data (az, azd, gh, terraform). The agent bundles this file and uses it
  to answer questions about the project.

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

function Get-RepoVar([string]$Name) {
    $v = & gh variable get $Name --repo $Repo 2>$null
    if ($LASTEXITCODE -eq 0) { $v.Trim() } else { $null }
}

function Get-TfVar([string]$Name) {
    $file = Join-Path $root 'infra\registry-connection\terraform.tfvars'
    if (-not (Test-Path $file)) { return $null }
    $m = Select-String -Path $file -Pattern "^\s*$Name\s*=\s*`"([^`"]*)`"" | Select-Object -First 1
    if ($m) { $m.Matches[0].Groups[1].Value } else { $null }
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
Push-Location $root
try {
    $subscriptionId = (& azd env get-value AZURE_SUBSCRIPTION_ID).Trim()
    $resourceGroup = (& azd env get-value AZURE_RESOURCE_GROUP).Trim()
    $account = (& azd env get-value AZURE_AI_ACCOUNT_NAME).Trim()
    $project = (& azd env get-value AZURE_AI_PROJECT_NAME).Trim()
    $location = (& azd env get-value AZURE_LOCATION).Trim()
    $envName = (& azd env get-value AZURE_ENV_NAME).Trim()
} finally { Pop-Location }

$rgId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"
$accountId = "$rgId/providers/Microsoft.CognitiveServices/accounts/$account"
$projectId = "$accountId/projects/$project"
$projectEndpoint = "https://$account.services.ai.azure.com/api/projects/$project"
$agentName = (Select-String -Path (Join-Path $root 'azure.yaml') -Pattern '^\s*name:\s*(\S+)\s*$' | Select-Object -Last 1).Matches[0].Groups[1].Value
$pipelineAppId = Get-RepoVar AZURE_CLIENT_ID
$audienceAppId = Get-TfVar token_audience
$registryTarget = Get-TfVar registry_target
$registryOidc = Get-TfVar oidc_provider_name
$githubOidc = Get-RepoVar JFROG_GITHUB_OIDC_PROVIDER
$jfrogRepo = Get-RepoVar JFROG_REPO
$stateAccount = Get-RepoVar RS_STORAGE_ACCOUNT
$stateContainer = Get-RepoVar RS_CONTAINER_NAME
$stateKey = Get-RepoVar TF_STATE_KEY
$runnerLocation = Get-RepoVar RUNNER_LOCATION

Write-Host '==> Collecting Azure resources'
$resources = Invoke-Json resource list -g $resourceGroup
$resourceRows = $resources | Sort-Object type, name | ForEach-Object {
    $res = $_
    $origin = switch ($res.tags.purpose) {
        'github-actions-runner' { 'Created: CI runner (infra/ci-runner)' }
        'terraform-state' { 'Created: Terraform state (bootstrap script)' }
        default {
            if ($res.type -like 'Microsoft.CognitiveServices/*') { 'Pre-existing: Foundry' }
            elseif ($res.name -like 'byor-ci*') { 'Created: CI runner (infra/ci-runner)' }
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
                    @{ id = $pipelineAppId; purpose = 'GitHub Actions deploy identity (federated, no secret)'; origin = 'Created: bootstrap script' })) {
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
        $roleRows += [pscustomobject]@{ Principal = 'GitHub Actions deploy identity'; Role = $ra.roleDefinitionName; Scope = Format-Scope $ra.scope }
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
$varNames = (& gh variable list --repo $Repo --json name | ConvertFrom-Json).name | Sort-Object
$lastRun = (& gh run list --repo $Repo --limit 1 --json displayTitle,conclusion,status,headSha,createdAt | ConvertFrom-Json) | Select-Object -First 1

$runnerVm = $resources | Where-Object { $_.type -eq 'Microsoft.Compute/virtualMachines' } | Select-Object -First 1
$runnerSize = if ($runnerVm) { (Invoke-Json vm show --ids $runnerVm.id).hardwareProfile.vmSize } else { 'n/a' }
$vnet = $resources | Where-Object { $_.type -eq 'Microsoft.Network/virtualNetworks' } | Select-Object -First 1
$vnetPrefix = if ($vnet) { ((Invoke-Json network vnet show --ids $vnet.id).addressSpace.addressPrefixes) -join ', ' } else { 'n/a' }

$image = (Select-String -Path (Join-Path $root 'azure.yaml') -Pattern '^\s*image:\s*"?([^"\s]+)"?' | Select-Object -First 1).Matches[0].Groups[1].Value
$jfrogHost = $image.Split('/')[0]

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
- **CI/CD**: GitHub Actions builds the image, pushes it to JFrog (GitHub OIDC), and applies Terraform for both the registry connection and hosted agent. The agent is managed through the Foundry data plane with AzAPI. All authentication uses OIDC; no secrets are stored.
- **Azure location**: resource group ``$resourceGroup``, Foundry in **$location**, CI runner in **$runnerLocation**. azd environment: ``$envName``.

## Foundry

- **Account**: ``$account`` ($location), pre-existing
- **Project**: ``$project``, endpoint ``$projectEndpoint``, identity type: $($projectRes.identity.type)

### Model deployments

$(ConvertTo-MdTable $deploymentRows @('Deployment', 'Model', 'Version', 'SKU'))

### Project connections

$(ConvertTo-MdTable $connectionRows @('Connection', 'Category', 'Target', 'Metadata'))

The ``private-registry`` connection is managed by **Terraform (AzAPI)** in ``infra/registry-connection``. It stores the OIDC token-exchange settings: Entra app audience, token endpoint ``/access/api/v1/oidc/token``, and JFrog provider name ``$registryOidc``.

### Hosted agent ``$agentName``

- **Latest version**: $($latest.version) ($($latest.status)), protocol: $(($latest.definition.protocol_versions | ForEach-Object { "$($_.protocol) $($_.version)" }) -join ', ')
- **Image**: ``$($latest.definition.container_configuration.image)`` via registry connection ``$($latest.definition.container_configuration.registry_connection_id)``
- **Agent identity**: platform-managed (blueprint ``$($latest.blueprint_reference.blueprint_id)``); it can call project models by default.

$(ConvertTo-MdTable $versionRows @('Version', 'Status', 'Created', 'Image', 'Resources', 'Env'))

## Azure resources in ``$resourceGroup``

$(ConvertTo-MdTable $resourceRows @('Name', 'Type', 'Region', 'Origin'))

### Terraform state

- **Registry connection** (``infra/registry-connection``): remote state in storage account ``$stateAccount``, container ``$stateContainer``, key ``$stateKey``. Entra auth only. Public network access is **disabled by subscription policy**, so state is reachable only through the private endpoint from the CI runner VNet.
- **Hosted agent** (``infra/hosted-agent``): separate remote state in the same account and container, key ``hosted-agent/$envName.tfstate``. It imports the existing logical agent, preserves Foundry version history, and prevents destroy.
- **CI runner** (``infra/ci-runner``): local state on the operator's machine.

### CI runner network

- **VM**: ``$($runnerVm.name)``, size **$runnerSize**, Ubuntu 24.04, region **$runnerLocation**. It has no public IP and no inbound rules, and is managed with ``az vm run-command``.
- **VNet**: ``$($vnet.name)`` ($vnetPrefix) with subnets ``runners`` and ``private-endpoints``.
- **Outbound**: Azure default outbound access. The subscription can't create public IPs, so a NAT gateway isn't possible.
- **Private endpoint**: blob endpoint of ``$stateAccount``, with private DNS zone ``privatelink.blob.core.windows.net``.
- **Why a different region**: eastus had no VM capacity when the runner was created.

## Microsoft Entra ID

$(ConvertTo-MdTable $appRows @('App', 'Purpose', 'Origin', 'Token version'))

### Federated credentials

$(ConvertTo-MdTable $fedRows @('App', 'Credential', 'Subject', 'Issuer'))

The repo uses GitHub's ID-based ("immutable") OIDC subjects, so the credential containing ``@`` IDs is the one in use.

### Role assignments

$(ConvertTo-MdTable $roleRows @('Principal', 'Role', 'Scope'))

## JFrog Artifactory

- **Instance**: ``$registryTarget``
- **Repositories**: ``$jfrogRepo`` (virtual; image path ``$jfrogHost/$jfrogRepo/agent``) and ``$jfrogRepo-local`` (local; where pushes land)
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

### Repository variables

$(($varNames | ForEach-Object { "``$_``" }) -join ', ')

## Repository layout

| Path | Purpose |
|---|---|
| ``app.py`` | FastAPI Responses-protocol agent (echo or model mode); serves ``/responses``, ``/readiness``, ``/liveness`` |
| ``azure.yaml`` | Legacy azd compatibility/reference definition; not the CI/CD source of truth |
| ``infra/registry-connection/`` | Terraform (AzAPI) for the Foundry registry connection |
| ``infra/hosted-agent/`` | Terraform (AzAPI data plane) for the logical hosted agent and versions |
| ``infra/ci-runner/`` | Terraform (AzAPI) for the runner VNet, private endpoint and VM |
| ``scripts/bootstrap-github-oidc.ps1`` | Entra app, federated credential, RBAC, state storage, GitHub variables |
| ``scripts/setup-runner.ps1`` | Provisions and registers the self-hosted runner |
| ``scripts/generate-asset-inventory.ps1`` | Generates this file |
| ``knowledge/`` | Knowledge files bundled into the agent image |
"@

# Redact every GUID (subscription, tenant, object, client IDs) and GitHub numeric owner/repo IDs in OIDC subjects.
$md = [regex]::Replace($md, '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', '<redacted>')
$md = [regex]::Replace($md, '(repo:[^@\s`]+)@\d+/([^@\s`]+)@\d+', '$1@<id>/$2@<id>')

New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
Set-Content -Path $OutFile -Value $md -Encoding utf8
Write-Host "==> Wrote $OutFile ($([Math]::Round((Get-Item $OutFile).Length / 1KB, 1)) KB)"
