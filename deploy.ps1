<#
.SYNOPSIS
  Deploy the hosted agent with Terraform (AzAPI) from a workstation.

  The Foundry<->JFrog registry connection is platform-owned (foundation repo) and is only consumed
  here. Connection name and project endpoint come from the published platform contract
  (foundry-<env>.json) or from explicit parameters. Foundation Terraform state is never read.

.EXAMPLE
  ./deploy.ps1 -ContractFile .\foundry-dev.json -Image yourtrial.jfrog.io/foundry-agents/agent@sha256:<digest>
  ./deploy.ps1 -ContractFile .\foundry-dev.json -Image <digest-ref> -AutoApprove
#>
[CmdletBinding()]
param(
    [switch]$AutoApprove,
    [string]$AgentService = 'private-registry-agent',
    # Digest-pinned reference: <registry-host>/<repo>/<image>@sha256:<64 hex>
    [Parameter(Mandatory)][string]$Image,
    [string]$ContractFile,
    [string]$ProjectEndpoint,
    [string]$RegistryConnectionName,
    [string]$ModelDeployment = 'gpt-5-mini'
)

$ErrorActionPreference = 'Stop'
$agentTfDir = Join-Path $PSScriptRoot 'infra\hosted-agent'

function Invoke-Checked {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
}

if ($ContractFile) {
    if (-not (Test-Path $ContractFile)) { throw "Contract file not found: $ContractFile" }
    $values = (Get-Content $ContractFile -Raw | ConvertFrom-Json).values
    if (-not $ProjectEndpoint) { $ProjectEndpoint = $values.FOUNDRY_PROJECT_ENDPOINT }
    if (-not $RegistryConnectionName) { $RegistryConnectionName = $values.JFROG_REGISTRY_CONNECTION_NAME }
}
if (-not $ProjectEndpoint) { throw 'Project endpoint unknown. Pass -ContractFile or -ProjectEndpoint.' }
if (-not $RegistryConnectionName) { throw 'Registry connection name unknown. Pass -ContractFile or -RegistryConnectionName.' }
if ($Image -notmatch '^[^/]+/.+@sha256:[0-9a-f]{64}$') { throw "Image must be digest-pinned (<host>/<repo>/<image>@sha256:<64 hex>), got '$Image'." }

if (-not (Test-Path (Join-Path $agentTfDir 'backend.hcl'))) {
    throw "Missing $agentTfDir\backend.hcl (remote state). Run scripts/bootstrap-github-oidc.ps1 first."
}

Write-Host "==> Terraform: hosted agent $AgentService (connection: $RegistryConnectionName)"
Invoke-Checked terraform @("-chdir=$agentTfDir", 'init', '-input=false', '-backend-config=backend.hcl')
Invoke-Checked terraform @(
    "-chdir=$agentTfDir", 'plan', '-input=false', '-out=tfplan',
    "-var=project_endpoint=$ProjectEndpoint",
    "-var=agent_name=$AgentService",
    "-var=image_uri=$Image",
    "-var=registry_connection_name=$RegistryConnectionName",
    "-var=model_deployment_name=$ModelDeployment",
    '-var=import_existing_agent=true'
)
if (-not $AutoApprove) {
    $answer = Read-Host 'Apply the hosted-agent plan? (y/N)'
    if ($answer -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; exit 1 }
}
Invoke-Checked terraform @("-chdir=$agentTfDir", 'apply', '-input=false', 'tfplan')
Remove-Item (Join-Path $agentTfDir 'tfplan') -ErrorAction SilentlyContinue

$version = (& terraform "-chdir=$agentTfDir" output -raw agent_version)
Write-Host "Hosted agent version: $version"
