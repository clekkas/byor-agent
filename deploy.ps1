<#
.SYNOPSIS
  Provision the Foundry registry connection with Terraform (AzAPI), then deploy the
  hosted agent with azd, exactly as before.

.EXAMPLE
  ./deploy.ps1                      # plan, prompt, apply, azd deploy
  ./deploy.ps1 -AutoApprove         # non-interactive
  ./deploy.ps1 -SkipAgentDeploy     # connection only
#>
[CmdletBinding()]
param(
    [switch]$AutoApprove,
    [switch]$SkipAgentDeploy,
    [string]$AgentService = 'private-registry-agent'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$tfDir = Join-Path $root 'infra\registry-connection'

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

Write-Host "==> azd: deploying $AgentService"
Push-Location $root
try {
    Invoke-Checked azd @('deploy', $AgentService, '--no-prompt')
} finally {
    Pop-Location
}
