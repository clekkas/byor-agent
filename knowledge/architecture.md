<!-- scope: architecture, runner, runners, vnet, private endpoint, oidc, drift, workflow, workflows, pipeline, pipelines, contract, state, tfstate, identity, identities, environment, environments, reviewers, digest, hosted agent, byor, platform repo, foundation repo, agent repo, composite action, concurrency, nsg, cloud-init, managed identity -->
# Architecture and workflows (condensed overview)

Written 2026-10-10 from the two repositories. This is newer than the generated asset inventory, so where the two differ (for example the agent version number, the number of runners or the federated credential subjects) prefer this document. Subscription, tenant and application IDs are redacted on purpose.

## What the system is

Two private GitHub repositories split one system. Together they deploy a hosted agent in Microsoft Foundry whose container image is pulled from a private JFrog registry. Foundry authenticates to JFrog with OIDC token exchange, and GitHub authenticates to Azure and JFrog with OIDC. No client secrets are stored anywhere.

| Repository | Owns |
|---|---|
| `jfrog-oidc-foundry` (foundation or platform repo) | The Foundry-to-JFrog registry connection, the runner VMs, the Terraform state storage, the foundation deploy identities, and the published platform contract |
| `jfrog-agent-byor` (agent repo, GitHub name `clekkas/byor-agent`) | The app, its image build, the hosted-agent Terraform, the smoke test and this knowledge base. It consumes the contract and never reads foundation state. |

Constraints that shape everything: GitHub OIDC to Azure with no stored secrets, separate foundation and agent Terraform state, and no hosted-agent versions deployed from the foundation repo.

## Current state

- Foundation cutover for the dev environment is done.
- The live agent is `private-registry-agent`, version 13, active, with the smoke test passing.
- The agent uses the Foundry project connection `jfrog-registry` in the project `workshop-demo-project`.
- Both legacy branch-based federated credentials were deleted. Credentials are now bound to GitHub environments.
- Required reviewers are disabled for now, so there is no human approval gate on deploys.

## Runners

There are two self-hosted runner VMs, both with the label `byor-private`, both Standard_B2s_v2 Ubuntu 24.04 in swedencentral, in resource group `<foundry-resource-group>`.

| VM | Registered to |
|---|---|
| `byor-ci-runner-01` | the foundation repo |
| `byor-ci-agent-runner-01` | the agent repo |

- They share the VNet `byor-ci-vnet`, the subnet `runners` and the network security group `byor-ci-runner-nsg`. The NSG rule `deny-vnet-inbound` blocks inbound traffic from other VNet hosts, so a job on one VM cannot reach the other.
- Why a private VNet: the Terraform state account `tfstateb173d2d85c34` has public network access disabled. The only way in is the private endpoint `byor-ci-tfstate-blob-pe`, with the private DNS zone `privatelink.blob.core.windows.net`. Anything that touches Terraform state must run inside the VNet. A 403 from a laptop is the symptom of running outside it.
- The VMs have no public IP and no inbound access. They are managed with `az vm run-command`, not SSH, and make only outbound connections.
- The VMs have no Azure identity of their own (no managed identity). The runner service runs as the non-admin Linux user `ghrunner`.
- Azure identity comes from the workflow, per job. The `azure/login` action exchanges a GitHub OIDC token for an Entra token, and the GitHub environment a job runs in decides which identity it gets:

| Job | GitHub environment | Entra identity |
|---|---|---|
| Foundation plan, drift and contract | `foundation-dev-plan` | the dev plan app (read-only) |
| Foundation apply | `foundation-dev` | the dev apply app (write) |
| Agent plan and deploy | `agent` | `github-byor-agent-deployer` |

- Caveats: jobs on a shared VM can see each other's leftovers and the Azure CLI token of the running job, which is why both repos must stay private. The foundation VM's OS disk is Standard_LRS while the agent VM's is StandardSSD_LRS, which has no functional effect. `cloud-init.yaml` installs `az` on new VMs, but the agent VM predates that line and had `az` installed by hand.

## What a workflow is here

A workflow is a GitHub Actions workflow: a YAML file in a repo's `.github/workflows` folder that runs automated steps when something happens. It is not a Terraform, Azure or Foundry concept; it is the pipeline that runs those tools. It has a trigger (push, pull request, schedule or manual dispatch), jobs (groups of steps on one machine, possibly dependent on each other) and steps (commands or reusable actions).

Related terms: a runner is the machine a job executes on (GitHub-hosted `ubuntu-latest` or a `byor-private` VM). An environment is a named GitHub setting that decides which Azure identity a job gets and whether a human must approve it. A composite action is a reusable bundle of steps without its own trigger; `foundation-init` is the only one, so the count is five workflows plus one composite action.

## The five workflows

Foundation repo, all jobs on `byor-ci-runner-01`:

| Workflow | Trigger | What it does |
|---|---|---|
| `foundation-plan` | Pull requests touching the foundation paths, or manual | Runs format check, validate and a read-only plan for every environment. Skips fork PRs so outside code never runs on the runner. |
| `foundation-apply` | Push to the main branch touching the same paths, or manual with a dev or prod choice | Three jobs. The plan job saves a plan file. The apply job applies exactly that saved plan, only when there are changes, behind the reviewer-gated environment. The contract job publishes `foundry-<env>.json` as an artifact kept 90 days. Refuses to run off the main branch. |
| `foundation-drift` | Nightly at 05:23 UTC, or manual | Plans every environment against live Azure. Drift opens or updates a GitHub issue labelled `foundation-drift` and fails the run. A clean plan closes the issue. |

The composite action `foundation-init` installs Terraform and runs `terraform init` against the environment's backend file.

Agent repo:

| Workflow | Trigger | What it does |
|---|---|---|
| `deploy-agent.yml` (Build and deploy hosted agent) | Push to the main branch touching `app.py`, `knowledge/**`, `requirements*.txt`, `Dockerfile`, `infra/hosted-agent/**`, the smoke test script or the workflow; or manual with an optional `image_tag` | The build job runs on `ubuntu-latest`: JFrog OIDC login, docker build, container smoke test, push, resolve the immutable digest. A manual run with `image_tag` skips build and push. The deploy job runs on `byor-ci-agent-runner-01`: Azure login, validate the contract against the live connection, then Terraform plan and apply with no pause, then wait for the version to become active and smoke test it. |
| `agent-plan.yml` (Plan hosted agent, no apply) | Manual only, optional `image_uri` | Runs `terraform plan` for `infra/hosted-agent` and never applies. |

Both agent workflows share the concurrency group `hosted-agent-deployment`, so they queue instead of overlapping.

## Design points

- Private state: every Terraform run happens on a `byor-private` runner inside the VNet.
- Environment-scoped OIDC: federated credentials are bound to GitHub environments, not branches.
- Separate plan and apply identities in the foundation repo, so pull request code can plan but never write.
- Digest-only deploys: images must be `@sha256:` references under the `JFROG_REPO` repository path. The workflow also re-checks the live connection target, type (`registry_connection`) and mode (`oauth_token_exchange`).
- State separation: foundation state is in container `foundation-tfstate` under `registry-connection/dev.tfstate`; agent state is in container `agent-tfstate` under `hosted-agent/dev.tfstate`.
- The Terraform in `infra/registry-connection` (foundation repo) manages two Foundry project connections with AzAPI and `prevent_destroy`: `jfrog-registry` is active and `legacy_registry` is still there.

## Risks and open items

- Reviewers are off. A push to the main branch that touches a deploy path (including `knowledge/**`) builds and deploys a new agent version with no human gate.
- No pause between plan and apply in `deploy-agent.yml`; run `agent-plan.yml` first for anything risky.
- The SKU allow-list exists twice (hardcoded in `infra/hosted-agent/main.tf` and in the repository variable `SUPPORTED_AGENT_SKUS`) and can drift apart.
- `legacy_registry` is still in the foundation Terraform and should be removed once the new connection is confirmed.
- The old state blobs `byor-demo.tfstate` remain until deletion is approved.
- In the agent repo the files `gitignore` and `dockerignore` have no leading dot, so neither Git nor Docker honours them. Some build artifacts are tracked that should not be.
- Model mode has not been tested end to end.
- The drift workflow queues if the foundation runner VM is off.
