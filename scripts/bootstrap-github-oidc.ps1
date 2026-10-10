<#
.SYNOPSIS
  One-time (re-runnable) setup of the AGENT deployment pipeline for this repository.

  This repo owns only: image build, JFrog push, hosted-agent Terraform and smoke tests.
  The Foundry<->JFrog registry connection, the CI runner, the state account and the
  foundation deploy identities belong to the foundation (platform) repo. This script only
  CONSUMES the platform contract it publishes.

  Creates or reuses, with no client secrets anywhere:
    - One Entra app + service principal for the agent deployer, with a GitHub OIDC federated
      credential bound to the GitHub Environment `agent` (not a branch)
    - A dedicated `agent-tfstate` container in the platform-owned state account, with
      container-scoped RBAC (this identity gets no role on the foundation state container)
    - Project/resource-group RBAC for the agent identity
    - The protected GitHub Environment `agent` (required reviewers, `main` only), holding the
      platform contract values plus the app-owned variables
    - infra/hosted-agent/backend.hcl (git-ignored) for local runs

  The contract file is the foundation repo's published artifact (foundry-<env>.json). Its
  valuesSha256 is verified before anything is written. Foundation Terraform state is never read.

.EXAMPLE
  ./scripts/bootstrap-github-oidc.ps1 -Repo contoso/agent-repo `
    -ContractFile .\foundry-dev.json -StateStorageAccount tfstateb173d2d85c34 `
    -Reviewers alice,contoso/agent-approvers
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repo,
    # foundry-<env>.json from the foundation repo's platform-contract-<env> artifact.
    [Parameter(Mandatory)][string]$ContractFile,
    # The platform-owned state account. It must already exist (created by the foundation bootstrap).
    [Parameter(Mandatory)][string]$StateStorageAccount,
    [string]$StateResourceGroup,
    [string]$StateContainer = 'agent-tfstate',
    [string]$EnvName,
    [string]$AppName = 'github-byor-agent-deployer',
    # GitHub users and/or org/team-slug required to approve deployments. Mandatory (unless -SkipGitHub).
    [string[]]$Reviewers = @(),
    [switch]$PreventSelfReview,
    [string]$ModelDeploymentName = 'gpt-5-mini',
    [string]$SupportedAgentSkus = '0.5:1Gi,1:2Gi,2:4Gi',
    [string]$RaiPolicyId = '',
    [string]$TerraformVersion = '1.9.8',
    [string]$RunnerLabel = 'byor-private',
    [switch]$SkipOperatorRole,
    [switch]$SkipGitHub
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$agentTfDir = Join-Path $root 'infra\hosted-agent'
$agentEnv = 'agent'

function Invoke-Az {
    $out = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed" }
    $out
}

function Set-RoleAssignment([string]$ObjectId, [string]$PrincipalType, [string]$Role, [string]$Scope) {
    $existing = Invoke-Az role assignment list --assignee $ObjectId --role $Role --scope $Scope --query "[].id" -o tsv
    if ($existing) { Write-Host "  = $Role ($PrincipalType)"; return }
    Invoke-Az role assignment create --assignee-object-id $ObjectId --assignee-principal-type $PrincipalType --role $Role --scope $Scope -o none
    Write-Host "  + $Role ($PrincipalType)"
}

# Canonical JSON of the flat values map: keys sorted ordinally, compact. Matches `jq -S -c .values`.
function Get-ValuesSha256([psobject]$Values) {
    $names = [string[]]@($Values.PSObject.Properties.Name)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    function Format-JsonString([string]$s) {
        $sb = [Text.StringBuilder]::new('"')
        foreach ($c in $s.ToCharArray()) {
            switch ($c) {
                '"' { [void]$sb.Append('\"') }
                '\' { [void]$sb.Append('\\') }
                "`n" { [void]$sb.Append('\n') }
                "`r" { [void]$sb.Append('\r') }
                "`t" { [void]$sb.Append('\t') }
                "`b" { [void]$sb.Append('\b') }
                "`f" { [void]$sb.Append('\f') }
                default { if ([int]$c -lt 0x20) { [void]$sb.AppendFormat('\u{0:x4}', [int]$c) } else { [void]$sb.Append($c) } }
            }
        }
        [void]$sb.Append('"')
        $sb.ToString()
    }
    $json = '{' + (($names | ForEach-Object { (Format-JsonString $_) + ':' + (Format-JsonString ([string]$Values.$_)) }) -join ',') + '}'
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '').ToLower()
}

# ---- Guards that must hold before anything is created ---------------------------------------
if (-not $SkipGitHub -and $Reviewers.Count -eq 0) {
    throw "-Reviewers is required (GitHub users and/or org/team-slug). The '$agentEnv' environment must have required reviewers, and re-running this script without them would clear any set earlier."
}
$visibility = (& gh repo view $Repo --json visibility --jq .visibility 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $visibility) { throw "Cannot read repository '$Repo' with gh. Run 'gh auth login' with admin access to the repo." }
if ($visibility -notin 'PRIVATE', 'INTERNAL') {
    throw "Repository '$Repo' is $visibility. It must be private or internal: the deploy job runs on the self-hosted runner, which has a private network path to Terraform state."
}
Write-Host "Repository visibility: $visibility"

# ---- Platform contract -------------------------------------------------------------------------
if (-not (Test-Path $ContractFile)) { throw "Contract file not found: $ContractFile" }
$contract = Get-Content $ContractFile -Raw | ConvertFrom-Json
if ($contract.contractVersion -ne '1') { throw "Unsupported contractVersion '$($contract.contractVersion)' (this script understands '1')." }
if (-not $contract.values) { throw "$ContractFile has no 'values' object." }
$actualSha = Get-ValuesSha256 $contract.values
if ($actualSha -ne $contract.valuesSha256) {
    throw "valuesSha256 mismatch. File says $($contract.valuesSha256), computed $actualSha. The contract was edited or is not the published artifact."
}
Write-Host "Contract: environment '$($contract.environment)', commit $($contract.source.commit), sha256 $actualSha (verified)"

$requiredKeys = 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'FOUNDRY_ACCOUNT_NAME', 'FOUNDRY_PROJECT_NAME',
'FOUNDRY_PROJECT_RESOURCE_ID', 'FOUNDRY_PROJECT_ENDPOINT', 'JFROG_REGISTRY_CONNECTION_NAME', 'JF_URL', 'JFROG_REPO', 'JFROG_GITHUB_OIDC_PROVIDER'
$missing = $requiredKeys | Where-Object { -not $contract.values.$_ }
if ($missing) { throw "Contract is missing required values: $($missing -join ', ')" }

$v = $contract.values
$SubscriptionId = $v.AZURE_SUBSCRIPTION_ID
$TenantId = $v.AZURE_TENANT_ID
$ResourceGroup = $v.AZURE_RESOURCE_GROUP
if (-not $StateResourceGroup) { $StateResourceGroup = $ResourceGroup }
if (-not $EnvName) { $EnvName = $contract.environment }
$rgId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$projectId = $v.FOUNDRY_PROJECT_RESOURCE_ID
$stateKey = "hosted-agent/$EnvName.tfstate"

Invoke-Az account set --subscription $SubscriptionId

# ---- Entra app + federated credential (environment-scoped) -------------------------------------
# GitHub may issue ID-based ("immutable") subjects, e.g. repo:owner@123/repo@456:...; use whatever prefix the repo reports.
$subPrefix = & gh api "repos/$Repo/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty' 2>$null
if ($LASTEXITCODE -ne 0 -or -not $subPrefix) { $subPrefix = "repo:$Repo" }
$subPrefix = $subPrefix.Trim()
$subject = "${subPrefix}:environment:$agentEnv"

Write-Host "==> Entra app '$AppName' (OIDC subject: environment:$agentEnv)"
$appId = Invoke-Az ad app list --display-name $AppName --query "[0].appId" -o tsv
if (-not $appId) {
    $appId = Invoke-Az ad app create --display-name $AppName --sign-in-audience AzureADMyOrg --query appId -o tsv
    Write-Host "  + app $appId"
} else { Write-Host "  = app $appId" }

$spId = Invoke-Az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv
if (-not $spId) {
    $spId = Invoke-Az ad sp create --id $appId --query id -o tsv
    Write-Host "  + service principal $spId"
} else { Write-Host "  = service principal $spId" }

$fics = Invoke-Az ad app federated-credential list --id $appId -o json | ConvertFrom-Json
if ($fics | Where-Object { $_.subject -eq $subject }) {
    Write-Host "  = federated credential $subject"
} else {
    $fic = @{
        name      = "github-$($Repo.Replace('/', '-'))-$agentEnv$(if ($subPrefix -match '@') { '-ids' })"
        issuer    = 'https://token.actions.githubusercontent.com'
        subject   = $subject
        audiences = @('api://AzureADTokenExchange')
    } | ConvertTo-Json -Compress
    $ficFile = New-TemporaryFile
    Set-Content -Path $ficFile -Value $fic -Encoding utf8
    try { Invoke-Az ad app federated-credential create --id $appId --parameters "@$ficFile" -o none } finally { Remove-Item $ficFile }
    Write-Host "  + federated credential $subject"
}
$legacy = $fics | Where-Object { $_.subject -ne $subject -and $_.subject -match ':ref:refs/heads/' }
if ($legacy) {
    Write-Warning "Legacy branch-subject credential(s) still on this app: $(($legacy | ForEach-Object name) -join ', '). Branch subjects bypass the environment's reviewers. Remove after cutover: az ad app federated-credential delete --id $appId --federated-credential-id <name>"
}

# ---- Terraform state: dedicated agent container in the platform-owned account ------------------
Write-Host "==> State storage '$StateStorageAccount' / container '$StateContainer'"
$saId = & az storage account show -n $StateStorageAccount -g $StateResourceGroup --query id -o tsv 2>$null
if (-not $saId) { throw "State account '$StateStorageAccount' not found in resource group '$StateResourceGroup'. It is created by the foundation repo's bootstrap; this repo does not create it." }
Write-Host "  = $saId"

# Management-plane create: works even when the account's public network access is disabled.
if ((Invoke-Az storage container-rm exists --storage-account $StateStorageAccount -g $StateResourceGroup -n $StateContainer --query exists -o tsv) -ne 'true') {
    Invoke-Az storage container-rm create --storage-account $StateStorageAccount -g $StateResourceGroup -n $StateContainer -o none
    Write-Host '  + container created'
} else { Write-Host '  = container exists' }
$containerScope = "$saId/blobServices/default/containers/$StateContainer"

# ---- RBAC ----------------------------------------------------------------------------------------
Write-Host '==> RBAC: agent identity'
Set-RoleAssignment $spId 'ServicePrincipal' 'Foundry Project Manager' $projectId
Set-RoleAssignment $spId 'ServicePrincipal' 'Reader' $rgId
Set-RoleAssignment $spId 'ServicePrincipal' 'Storage Blob Data Contributor' $containerScope

if (-not $SkipOperatorRole) {
    Write-Host '==> RBAC: you (local terraform against agent state)'
    $me = Invoke-Az ad signed-in-user show --query id -o tsv
    Set-RoleAssignment $me 'User' 'Storage Blob Data Contributor' $containerScope
}

# The agent identity must not be able to touch foundation state: no blob data role anywhere except its own container.
Write-Host '==> Check: agent identity has blob data roles only on its own container'
$wide = Invoke-Az role assignment list --assignee $spId --all --query "[?starts_with(roleDefinitionName,'Storage Blob Data') && scope!='$containerScope'].{role:roleDefinitionName,scope:scope,id:id}" -o json | ConvertFrom-Json
if ($wide) {
    $wide | Format-Table -AutoSize | Out-String | Write-Host
    throw "The agent identity ($appId) holds blob data roles outside '$StateContainer' (listed above), so it could read or write foundation state. Remove them, e.g.: az role assignment delete --ids <id>, then re-run."
}
Write-Host '  ok'

# ---- Local backend config (git-ignored) ----------------------------------------------------------
@"
resource_group_name  = "$StateResourceGroup"
storage_account_name = "$StateStorageAccount"
container_name       = "$StateContainer"
key                  = "$stateKey"
use_azuread_auth     = true
"@ | Set-Content -Path (Join-Path $agentTfDir 'backend.hcl') -Encoding utf8
Write-Host '==> Wrote infra/hosted-agent/backend.hcl (git-ignored)'

# ---- GitHub ----------------------------------------------------------------------------------------
function Resolve-Reviewer([string]$Name) {
    if ($Name -match '^(?<org>[^/]+)/(?<slug>.+)$') {
        $id = & gh api "orgs/$($Matches.org)/teams/$($Matches.slug)" --jq .id
        @{ type = 'Team'; id = [int64]$id }
    } else {
        $id = & gh api "users/$Name" --jq .id
        @{ type = 'User'; id = [int64]$id }
    }
}

function Set-GitHubVariable([string]$Name, [string]$Value, [string]$Environment) {
    if ($Environment) { & gh variable set $Name --repo $Repo --env $Environment --body $Value | Out-Null }
    else { & gh variable set $Name --repo $Repo --body $Value | Out-Null }
    if ($LASTEXITCODE -ne 0) { throw "gh variable set $Name failed" }
    Write-Host "  $Name = $Value"
}

if (-not $SkipGitHub) {
    Write-Host "==> GitHub environment '$agentEnv'"
    $body = @{
        deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }
        reviewers                = @($Reviewers | ForEach-Object { Resolve-Reviewer $_ })
        prevent_self_review      = [bool]$PreventSelfReview
    }
    $body | ConvertTo-Json -Depth 5 | & gh api -X PUT "repos/$Repo/environments/$agentEnv" --input - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not create environment $agentEnv (required reviewers need a GitHub plan that supports them on this repo)" }

    $existing = & gh api "repos/$Repo/environments/$agentEnv/deployment-branch-policies" --jq '.branch_policies[].name'
    if ($existing -notcontains 'main') {
        @{ name = 'main'; type = 'branch' } | ConvertTo-Json | & gh api -X POST "repos/$Repo/environments/$agentEnv/deployment-branch-policies" --input - | Out-Null
    }

    # Read back: fail loudly rather than leave the deploy identity reachable without approval.
    $envInfo = & gh api "repos/$Repo/environments/$agentEnv" | ConvertFrom-Json
    $reviewerCount = @($envInfo.protection_rules | Where-Object type -eq 'required_reviewers' | ForEach-Object { $_.reviewers }).Count
    if ($reviewerCount -lt 1) { throw "Environment '$agentEnv' has no required reviewers after configuration." }
    if (-not $envInfo.deployment_branch_policy.custom_branch_policies) { throw "Environment '$agentEnv' is not restricted to custom deployment branches." }
    $branches = & gh api "repos/$Repo/environments/$agentEnv/deployment-branch-policies" --jq '[.branch_policies[].name] | join(",")'
    Write-Host "  verified: $reviewerCount required reviewer(s); deployment branches: $branches"
    if ($branches -ne 'main') { Write-Warning "Deployment branches for '$agentEnv' are '$branches', expected only 'main'. Remove extras in Settings -> Environments." }

    Write-Host "==> Variables on environment '$agentEnv': platform contract (copied from $ContractFile)"
    foreach ($name in ($v.PSObject.Properties.Name | Sort-Object)) { Set-GitHubVariable $name ([string]$v.$name) $agentEnv }

    Write-Host "==> Variables on environment '$agentEnv': app-owned"
    $appVars = [ordered]@{
        AGENT_AZURE_CLIENT_ID       = $appId
        AGENT_STATE_RESOURCE_GROUP  = $StateResourceGroup
        AGENT_STATE_STORAGE_ACCOUNT = $StateStorageAccount
        AGENT_STATE_CONTAINER       = $StateContainer
        AGENT_STATE_KEY             = $stateKey
        MODEL_DEPLOYMENT_NAME       = $ModelDeploymentName
        SUPPORTED_AGENT_SKUS        = $SupportedAgentSkus
    }
    if ($RaiPolicyId) { $appVars.RAI_POLICY_ID = $RaiPolicyId }
    foreach ($k in $appVars.Keys) { Set-GitHubVariable $k $appVars[$k] $agentEnv }

    # runs-on is evaluated before the environment is entered, so these two must be repository-level.
    Write-Host '==> Repository variables (read by runs-on / tool setup)'
    Set-GitHubVariable RUNNER_LABEL $RunnerLabel $null
    Set-GitHubVariable TERRAFORM_VERSION $TerraformVersion $null

    # Old single-repo setup left foundation/registry values at repository level. They are inert for
    # the agent workflow but misleading and unprotected; list them for manual cleanup (never deleted here).
    $stale = & gh variable list --repo $Repo --json name --jq '.[].name' 2>$null |
        Where-Object { $_ -match '^(AZURE_|FOUNDRY_|JF|REGISTRY_|RS_|TF_STATE_KEY|FOUNDATION_|PLATFORM_CONTRACT_)' }
    if ($stale) {
        Write-Warning "Stale repository-level variables from the old single-repo setup: $($stale -join ', '). Delete them: gh variable delete <NAME> --repo $Repo"
    }
}

Write-Host @"

==> Done for '$EnvName'.
  agent identity : $AppName ($appId)  <- environment $agentEnv
  agent state    : $StateStorageAccount / $StateContainer / $stateKey

Remaining manual steps:
  1. JFrog ($($v.JF_URL)): the GitHub OIDC integration '$($v.JFROG_GITHUB_OIDC_PROVIDER)' identity mapping must allow
       Claims JSON : {"repository":"$Repo","ref":"refs/heads/main"}   (the ref claim is still present in environment-scoped tokens)
       Token scope : Read + Deploy/Cache on the repo behind '$($v.JFROG_REPO)'
  2. Runner and state private endpoint are platform-owned: confirm the runner labelled '$RunnerLabel' is online for this repo
     (see the foundation repo README). This repo does not provision it.
  3. Approvers for '$agentEnv' will see one approval prompt per job that uses the environment (build and deploy).
"@
