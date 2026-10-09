<#
.SYNOPSIS
  Provision the Foundry registry connection and hosted agent with Terraform (AzAPI).

.EXAMPLE
  ./deploy.ps1                      # plan, prompt, apply both Terraform stacks
  ./deploy.ps1 -AutoApprove         # non-interactive
  ./deploy.ps1 -SkipAgentDeploy     # connection only
#>
[CmdletBinding()]
param(
    [switch]$AutoApprove,
    [switch]$SkipAgentDeploy,
    [string]$AgentService = 'private-registry-agent',
    [string]$Image,
    [string]$ProjectEndpoint,
    [string]$ModelDeployment = 'gpt-5-mini'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$tfDir = Join-Path $root 'infra\registry-connection'
$agentTfDir = Join-Path $root 'infra\hosted-agent'

function Invoke-Checked {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
}

if (-not (Test-Path (Join-Path $tfDir 'terraform.tfvars'))) {
    throw "Missing $tfDir\terraform.tfvars. Copy terraform.tfvars.example and fill it in."
}
if (-not (Test-Path (Join-Path $tfDir 'backend.hcl'))) {
    throw "Missing $tfDir\backend.hcl (remote state). Run scripts/bootstrap-github-oidc.ps1 first."
}
Write-Host '==> Terraform: registry connection (AzAPI)'
Invoke-Checked terraform @("-chdir=$tfDir", 'init', '-input=false', '-backend-config=backend.hcl')
Invoke-Checked terraform @("-chdir=$tfDir", 'plan', '-input=false', '-out=tfplan')
if (-not $AutoApprove) {
    $answer = Read-Host 'Apply this plan? (y/N)'
    if ($answer -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; exit 1 }
}
Invoke-Checked terraform @("-chdir=$tfDir", 'apply', '-input=false', 'tfplan')
Remove-Item (Join-Path $tfDir 'tfplan') -ErrorAction SilentlyContinue

$connectionName = (& terraform "-chdir=$tfDir" output -raw registry_connection_name)
$principalId = (& terraform "-chdir=$tfDir" output -raw project_principal_id)
Write-Host "Registry connection: $connectionName"
Write-Host "Project identity (bind in JFrog OIDC identity mapping): $principalId"

$yaml = Get-Content (Join-Path $root 'azure.yaml') -Raw
if ($yaml -notmatch "registryConnectionId:\s*[`"']?$([regex]::Escape($connectionName))[`"']?\s") {
    throw "azure.yaml registryConnectionId does not match Terraform connection '$connectionName'."
}

if ($SkipAgentDeploy) { return }

if (-not (Test-Path (Join-Path $agentTfDir 'backend.hcl'))) {
    throw "Missing $agentTfDir\backend.hcl (remote state). Run scripts/bootstrap-github-oidc.ps1 first."
}

if (-not $Image) {
    $match = [regex]::Match($yaml, '(?m)^\s*image:\s*["'']?([^"''\s]+)')
    if (-not $match.Success) { throw 'Unable to read the image from azure.yaml. Pass -Image explicitly.' }
    $Image = $match.Groups[1].Value
}
if (-not $ProjectEndpoint) {
    $match = [regex]::Match($yaml, '(?m)^\s*endpoint:\s*(https://\S+)')
    if (-not $match.Success) { throw 'Unable to read the project endpoint from azure.yaml. Pass -ProjectEndpoint explicitly.' }
    $ProjectEndpoint = $match.Groups[1].Value
}

Write-Host "==> Terraform: hosted agent $AgentService"
Invoke-Checked terraform @("-chdir=$agentTfDir", 'init', '-input=false', '-backend-config=backend.hcl')
Invoke-Checked terraform @(
    "-chdir=$agentTfDir", 'plan', '-input=false', '-out=tfplan',
    "-var=project_endpoint=$ProjectEndpoint",
    "-var=agent_name=$AgentService",
    "-var=image_uri=$Image",
    "-var=registry_connection_name=$connectionName",
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
