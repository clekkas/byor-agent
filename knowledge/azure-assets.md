# Asset inventory: Foundry BYOR hosted agent (JFrog + OIDC)

Generated 2026-10-07 01:51 UTC by `scripts/generate-asset-inventory.ps1` from live Azure, GitHub and Terraform data.
IDs (subscription, tenant, object and client IDs) are redacted. Secrets are never collected.

## Summary

- **Project**: a Microsoft Foundry hosted agent (`private-registry-agent`) whose container image is stored in **JFrog Artifactory**, not Azure Container Registry ("bring your own registry").
- **Image pull**: Foundry pulls the image using **OIDC token exchange**. The Foundry project's managed identity exchanges an Entra token for a short-lived JFrog token, so no registry password is stored.
- **Model**: the agent answers with model **`gpt-5-mini`** through the Foundry project endpoint, using its own platform-managed identity.
- **CI/CD**: GitHub Actions builds the image, pushes it to JFrog (GitHub OIDC), applies Terraform for the registry connection, and deploys the agent with `azd`. All logins use OIDC; no secrets are stored.
- **Azure location**: resource group `kaiser-foundry-rg`, Foundry in **eastus**, CI runner in **swedencentral**. azd environment: `byor-demo`.

## Foundry

- **Account**: `kaiser-foundry-resource` (eastus), pre-existing
- **Project**: `workshop-demo-project`, endpoint `https://kaiser-foundry-resource.services.ai.azure.com/api/projects/workshop-demo-project`, identity type: SystemAssigned

### Model deployments

| Deployment | Model | Version | SKU |
|---|---|---|---|
| `gpt-5-mini` | gpt-5-mini | 2025-08-07 | GlobalStandard |

### Project connections

| Connection | Category | Target | Metadata |
|---|---|---|---|
| `private-registry` | CustomKeys | https://trialndswdc.jfrog.io | mode=oauth_token_exchange, type=registry_connection |

The `private-registry` connection is managed by **Terraform (AzAPI)** in `infra/registry-connection`. It stores the OIDC token-exchange settings: Entra app audience, token endpoint `/access/api/v1/oidc/token`, and JFrog provider name `oidc-byor`.

### Hosted agent `private-registry-agent`

- **Latest version**: 6 (active), protocol: responses 2.0.0
- **Image**: `trialndswdc.jfrog.io/byor-demo-docker/agent:sha-2c36d2b` via registry connection `private-registry`
- **Agent identity**: platform-managed (blueprint `private-registry-agent-dd7ed`); it can call project models by default.

| Version | Status | Created | Image | Resources | Env |
|---|---|---|---|---|---|
| 6 | active | 2026-10-07 01:30 UTC | `trialndswdc.jfrog.io/byor-demo-docker/agent:sha-2c36d2b` | 0.5 CPU / 1Gi | AZURE_AI_MODEL_DEPLOYMENT_NAME=gpt-5-mini |
| 5 | active | 2026-10-07 01:10 UTC | `trialndswdc.jfrog.io/byor-demo-docker/agent:sha-918578d` | 0.5 CPU / 1Gi | (none: echo mode) |
| 4 | active | 2026-10-06 23:28 UTC | `trialndswdc.jfrog.io/byor-demo-docker/agent:0.2` | 0.5 CPU / 1Gi | (none: echo mode) |
| 3 | active | 2026-10-06 23:23 UTC | `trialndswdc.jfrog.io/byor-demo-docker/agent:0.1` | 0.5 CPU / 1Gi | (none: echo mode) |
| 2 | active | 2026-10-06 21:37 UTC | `trialrpqe22.jfrog.io/cl-docker/agent:0.1` | 0.5 CPU / 1Gi | (none: echo mode) |
| 1 | active | 2026-10-06 21:36 UTC | `trialrpqe22.jfrog.io/cl-docker/agent:0.1` | 0.5 CPU / 1Gi | (none: echo mode) |

## Azure resources in `kaiser-foundry-rg`

| Name | Type | Region | Origin |
|---|---|---|---|
| `kaiser-foundry-resource` | Microsoft.CognitiveServices/accounts | eastus | Pre-existing: Foundry |
| `kaiser-foundry-resource/workshop-demo-project` | Microsoft.CognitiveServices/accounts/projects | eastus | Pre-existing: Foundry |
| `byor-ci-runner-01_OsDisk_1_ffb7fab3b34e4d11a67e920b1139afb9` | Microsoft.Compute/disks | swedencentral | Created: CI runner (infra/ci-runner) |
| `byor-ci-runner-key` | Microsoft.Compute/sshPublicKeys | swedencentral | Created: CI runner (infra/ci-runner) |
| `byor-ci-runner-01` | Microsoft.Compute/virtualMachines | swedencentral | Created: CI runner (infra/ci-runner) |
| `byor-ci-runner-nic` | Microsoft.Network/networkInterfaces | swedencentral | Created: CI runner (infra/ci-runner) |
| `byor-ci-tfstate-blob-pe.nic.<redacted>` | Microsoft.Network/networkInterfaces | swedencentral | Created: CI runner (infra/ci-runner) |
| `byor-ci-runner-nsg` | Microsoft.Network/networkSecurityGroups | swedencentral | Created: CI runner (infra/ci-runner) |
| `privatelink.blob.core.windows.net` | Microsoft.Network/privateDnsZones | global | Created: CI runner (infra/ci-runner) |
| `privatelink.blob.core.windows.net/byor-ci-vnet-link` | Microsoft.Network/privateDnsZones/virtualNetworkLinks | global | Created: CI runner (infra/ci-runner) |
| `byor-ci-tfstate-blob-pe` | Microsoft.Network/privateEndpoints | swedencentral | Created: CI runner (infra/ci-runner) |
| `byor-ci-vnet` | Microsoft.Network/virtualNetworks | swedencentral | Created: CI runner (infra/ci-runner) |
| `tfstateb173d2d85c34` | Microsoft.Storage/storageAccounts | eastus | Created: Terraform state (bootstrap script) |

### Terraform state

- **Registry connection** (`infra/registry-connection`): remote state in storage account `tfstateb173d2d85c34`, container `tfstate`, key `registry-connection/byor-demo.tfstate`. Entra auth only. Public network access is **disabled by subscription policy**, so state is reachable only through the private endpoint from the CI runner VNet.
- **CI runner** (`infra/ci-runner`): local state on the operator's machine.

### CI runner network

- **VM**: `byor-ci-runner-01`, size **Standard_B2s_v2**, Ubuntu 24.04, region **swedencentral**. It has no public IP and no inbound rules, and is managed with `az vm run-command`.
- **VNet**: `byor-ci-vnet` (10.250.0.0/24) with subnets `runners` and `private-endpoints`.
- **Outbound**: Azure default outbound access. The subscription can't create public IPs, so a NAT gateway isn't possible.
- **Private endpoint**: blob endpoint of `tfstateb173d2d85c34`, with private DNS zone `privatelink.blob.core.windows.net`.
- **Why a different region**: eastus had no VM capacity when the runner was created.

## Microsoft Entra ID

| App | Purpose | Origin | Token version |
|---|---|---|---|
| `Foundry-Registry-Agent` | Token audience for the JFrog OIDC exchange (Foundry pulls images) | Pre-existing | v2 |
| `github-byor-agent-deployer` | GitHub Actions deploy identity (federated, no secret) | Created: bootstrap script | v2 |

### Federated credentials

| App | Credential | Subject | Issuer |
|---|---|---|---|
| `github-byor-agent-deployer` | `github-clekkas-byor-agent-main` | `repo:clekkas/byor-agent:ref:refs/heads/main` | https://token.actions.githubusercontent.com |
| `github-byor-agent-deployer` | `github-clekkas-byor-agent-main-ids` | `repo:clekkas@<id>/byor-agent@<id>:ref:refs/heads/main` | https://token.actions.githubusercontent.com |

The repo uses GitHub's ID-based ("immutable") OIDC subjects, so the credential containing `@` IDs is the one in use.

### Role assignments

| Principal | Role | Scope |
|---|---|---|
| GitHub Actions deploy identity | Foundry Project Manager | accounts `kaiser-foundry-resource` / projects `workshop-demo-project` |
| GitHub Actions deploy identity | Reader | resource group `kaiser-foundry-rg` |
| GitHub Actions deploy identity | Storage Blob Data Contributor | storageAccounts `tfstateb173d2d85c34` |
| Operator (user) | Storage Blob Data Contributor | storageAccounts `tfstateb173d2d85c34` |

## JFrog Artifactory

- **Instance**: `https://trialndswdc.jfrog.io`
- **Repositories**: `byor-demo-docker` (virtual; image path `trialndswdc.jfrog.io/byor-demo-docker/agent`) and `byor-demo-docker-local` (local; where pushes land)
- **Image tags**: CI pushes `agent:sha-<commit>`. Tags `0.1` and `0.2` were pushed by hand during setup.
- **OIDC integrations**:

| Integration | Used by | Trusts | Access |
|---|---|---|---|
| `oidc-byor` | Foundry (image pull) | Entra tenant (Azure provider), audience = the token-audience Entra app; identity mapping on the project managed identity (`oid`) | Read-only on `byor-demo-docker` |
| `github-oidc` | GitHub Actions build job (image push) | `https://token.actions.githubusercontent.com`, organization `clekkas`; mapping `repository=clekkas/byor-agent`, `ref=refs/heads/main` | Read + Deploy on `byor-demo-docker-local` |

## GitHub (`clekkas/byor-agent`)

- **Workflow**: `.github/workflows/deploy-agent.yml`. `build` runs on ubuntu-latest; `deploy` runs on the self-hosted runner. It triggers on pushes to `main` and on manual dispatch, with optional `image_tag`.
- **Last run**: "Enable model mode with gpt-5-mini via the Foundry project endpoint": completed/success at commit `2c36d2b`

### Self-hosted runners

| Runner | Status | Labels |
|---|---|---|
| `byor-ci-runner-01` | online | self-hosted, Linux, X64, byor-private |

### Repository variables

`AZURE_CLIENT_ID`, `AZURE_ENV_NAME`, `AZURE_LOCATION`, `AZURE_RESOURCE_GROUP`, `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, `FOUNDRY_ACCOUNT_NAME`, `FOUNDRY_PROJECT_ENDPOINT`, `FOUNDRY_PROJECT_NAME`, `JF_URL`, `JFROG_GITHUB_OIDC_PROVIDER`, `JFROG_REPO`, `REGISTRY_CONNECTION_NAME`, `REGISTRY_IMPORT_EXISTING`, `REGISTRY_OIDC_PROVIDER_NAME`, `REGISTRY_TOKEN_AUDIENCE`, `REGISTRY_TOKEN_ENDPOINT`, `RS_CONTAINER_NAME`, `RS_RESOURCE_GROUP`, `RS_STORAGE_ACCOUNT`, `RUNNER_LABEL`, `RUNNER_LOCATION`, `TERRAFORM_VERSION`, `TF_STATE_KEY`

## Repository layout

| Path | Purpose |
|---|---|
| `app.py` | FastAPI Responses-protocol agent (echo or model mode); serves `/responses`, `/readiness`, `/liveness` |
| `azure.yaml` | azd service definition (image, registry connection, env) |
| `infra/registry-connection/` | Terraform (AzAPI) for the Foundry registry connection |
| `infra/ci-runner/` | Terraform (AzAPI) for the runner VNet, private endpoint and VM |
| `scripts/bootstrap-github-oidc.ps1` | Entra app, federated credential, RBAC, state storage, GitHub variables |
| `scripts/setup-runner.ps1` | Provisions and registers the self-hosted runner |
| `scripts/generate-asset-inventory.ps1` | Generates this file |
| `knowledge/` | Knowledge files bundled into the agent image |

## Capital Cities 
Greece = Athina 
Thailand = Kuntep