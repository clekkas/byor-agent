<!-- scope: runbook, bootstrap, cutover, migrate, migration, state, tfstate, import, deploy, deployment, rollback, plan, apply, drift, contract, rbac, role, roles, permission, permissions, reviewers, checklist, troubleshoot, troubleshooting, sku, skus, smoke test, digest, terraform, runner, runners, queued, offline, 403, 422, onboarding, prod, dev, environment, federated credential -->
# Runbook (condensed): how to operate the foundation and the agent

Written 2026-10-10, condensed from the READMEs of both repositories. IDs are redacted. Use it for the procedure and the reasoning; for exact current values see the architecture document.

## Standing safety rules

- Do not run Terraform apply until the plan has been reviewed and approved by the owner.
- If a plan tries to create an existing JFrog registry connection or Foundry project connection, stop. The connection exists in Azure but not in the state. Fix it with an import block or by importing the existing resource, then re-plan. Never apply as is.
- If a plan wants to destroy or replace anything, stop. It means wrong state, wrong variables or drift. `prevent_destroy` also blocks it.
- Never commit state files, plan files or tfvars containing secrets. Never make either repository public.

## Ownership

The foundation repo owns the Foundry-to-JFrog connection, the state account and its RBAC, the foundation deploy identities, the runners and the contract. The agent repo owns the image build, the JFrog push, the hosted-agent Terraform, the smoke test and its own deploy identity. The agent repo must never read foundation state: it uses only the contract.

## The platform contract

After every successful foundation apply, including runs with no changes, the contract job builds `foundry-<env>.json` and uploads it as the artifact `platform-contract-<env>` (90 days). It has a flat `values` map and a `valuesSha256` digest over the sorted values. The contract holds identifiers and endpoints only, never secrets. Changes inside contract version 1 may add variables but never rename or remove them.

| Key | Meaning |
|---|---|
| `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_RESOURCE_GROUP` | Where the Foundry project lives |
| `FOUNDRY_ACCOUNT_NAME`, `FOUNDRY_PROJECT_NAME`, `FOUNDRY_PROJECT_RESOURCE_ID`, `FOUNDRY_PROJECT_ENDPOINT` | The project that agents are released into |
| `FOUNDRY_PROJECT_PRINCIPAL_ID` | The project managed identity that pulls images from JFrog |
| `JFROG_REGISTRY_CONNECTION_NAME`, `JFROG_REGISTRY_CONNECTION_ID` | The connection that hosted agents reference |
| `JF_URL` | JFrog base URL |
| `JFROG_REPO` | Docker repository key in image paths |
| `JFROG_GITHUB_OIDC_PROVIDER` | JFrog OIDC provider name for GitHub pushes |
| `REGISTRY_TOKEN_AUDIENCE`, `REGISTRY_TOKEN_ENDPOINT`, `REGISTRY_OIDC_PROVIDER_NAME` | Entra-to-JFrog token exchange settings |

The agent workflow uses the tenant, subscription, resource group, account, project, project resource ID, endpoint, connection name, `JF_URL`, `JFROG_REPO` and `JFROG_GITHUB_OIDC_PROVIDER`.

How the agent repo gets the values: an admin takes them from the published artifact (never from Terraform state or terraform output), checks that the digest matches, and writes them as variables on the protected `agent` GitHub environment of the agent repo. Environment variables are used rather than repository variables so that changing the target Foundry project needs the same approval as deploying to it. Re-run the agent bootstrap script to refresh them after a new contract.

## State layout

One storage account, `tfstateb173d2d85c34`, public access disabled, reachable only through the private endpoint. Foundation state is in container `foundation-tfstate`, key `registry-connection/dev.tfstate`. Agent state is in container `agent-tfstate`, key `hosted-agent/dev.tfstate`. Blob data roles are granted at container scope only. The agent identity must never hold a blob data role at account or resource-group scope; the bootstrap script lists such assignments for review and fails if it finds one. App code must not use `terraform_remote_state` against foundation state.

The old state location was container `tfstate`, key `registry-connection/byor-demo.tfstate`. It was copied with the migrate script (a verified SHA-256 copy that never modifies the source) and is kept as a rollback copy until the new pipeline has been stable for a while.

## RBAC summary

| Principal | Role | Scope |
|---|---|---|
| Foundation apply identity | Foundry Project Manager | Foundry project |
| Foundation apply identity | Reader | Resource group |
| Foundation apply identity | Storage Blob Data Contributor | `foundation-tfstate` container |
| Foundation plan identity | Reader | Resource group |
| Foundation plan identity | Storage Blob Data Reader | `foundation-tfstate` container |
| Agent deploy identity | Storage Blob Data Contributor | `agent-tfstate` container only |
| Agent deploy identity | Foundry Project Manager | Foundry project |
| Agent deploy identity | Reader | Resource group |

Caution: the built-in Foundry Project Manager role can also write project connections, so the agent deployer could in principle alter the registry connection. Drift detection is the safety net; a narrower custom role is the alternative.

## OIDC and environments

Each identity has one federated credential bound to a GitHub environment, not a branch: subject `repo:<owner>/<repo>:environment:<name>`. Foundation has `foundation-<env>` (apply, restricted to the main branch, reviewers required when enabled) and `foundation-<env>-plan` (read-only, no protection). The agent repo has the `agent` environment. Each environment holds `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`, which are identifiers and not secrets. Repository variables are `TERRAFORM_VERSION` and `RUNNER_LABEL`.

## Setup order for a new environment

1. Foundation: fill in the environment tfvars and backend file (for prod, copy the example files, use a separate state key, ideally a separate subscription and storage account). `jfrog_repository_key` is required and has no default.
2. Run the foundation bootstrap script with the environment name and reviewers. It refuses a public repository, creates the two Entra apps with federated credentials, the state container with container-scoped RBAC, and the GitHub environments, then reads the environment back to verify reviewers and the main-only branch policy. `-NoRequiredReviewers` is a temporary opt-out for GitHub plans that reject required reviewers (HTTP 422 mentioning the billing plan).
3. Run the runner setup script, once for the foundation runner and once with `-RunnerKey agent` for the agent runner.
4. Migrate old state only if it exists in the old location, then verify with a state list and a plan.
5. Run the cutover checks below, apply through the pipeline, and confirm the contract artifact.
6. Agent repo: download the contract, run the agent bootstrap script with the contract file and the state storage account, then configure the JFrog GitHub OIDC provider with an identity mapping on the repository and main branch, scoped to read plus deploy on the local Docker repository behind `JFROG_REPO`.

## Cutover checklist (summary)

1. Repository is private or internal; branch protection noted.
2. Offline checks pass: format check, init without backend and validate in both Terraform directories.
3. The old pipeline is frozen (workflow disabled, nothing running).
4. Bootstrap done and verified: both federated credentials have the expected environment subjects, no client secrets exist (credential count is zero), container-scoped roles are correct and no account-scope blob data role exists for an app identity.
5. Runners are online with the label `byor-private`, the local state file for `infra/ci-runner` exists and has a backup.
6. State migrated and the plan shows no changes. Interpreting a plan: create of a registry connection means missing import; destroy or replace means stop; in-place update of the body only is drift to review; a state lock error or 403 means the old pipeline is still running or a role is missing.
7. Contract preview builds and shows the expected `JFROG_REPO`.
8. First CI run: a harmless pull request plans cleanly with no approval request; a manual apply from a non-main branch must fail with "Foundation apply only runs from main"; after merge the contract artifact checks out and drift runs green.
9. Go or no-go. Rollback before the first apply means re-enabling the old workflow. After the first apply the old and new states diverge.

## Deploying the agent

CI path: push to the main branch touching a deploy path, or run `deploy-agent.yml` manually. For anything risky run `agent-plan.yml` first (it never applies). Both are serialized by the concurrency group. The image tag is `sha-<commit>`; Terraform only receives the immutable `@sha256:` digest. Preflight fails the run before Terraform if the contract variables, project endpoint, connection (target, type, mode), digest repository or requested SKU are wrong.

Manual path: `deploy.ps1` or `deploy.sh` with the contract file and a digest-pinned image, from a machine that can reach the private state endpoint. For the first apply keep `import_existing_agent` true so Terraform adopts the existing logical agent; the plan must import and update in place with no destroy.

Validation: the smoke test script waits for the exact Terraform output version to become active, checks that its image matches, and invokes the Responses endpoint. A successful apply is not readiness.

## Troubleshooting

- Deploy job stays queued: the `byor-private` runner for that repo is offline; bring the VM back and check the runner service.
- `Unable to locate executable file: az` in a login step: the runner VM lacks the Azure CLI; install it on the VM.
- 403 on state: you are outside the VNet, or the identity lacks the container role.
- HTTP 422 creating an environment with reviewers: the GitHub plan does not support required reviewers on private repositories; use the opt-out and restore reviewers later.
- Workflow run 422 on dispatch: the workflow is disabled; re-enable it.
- Plan wants to create a connection: stop and import (see the standing rules).
- Local runner state lost: restore the newest backup of the `infra/ci-runner` state from `.foundry-platform/ci-runner-state` in the home folder, or import each resource. Never use `git clean -x` in that folder. Losing it does not lose foundation state, but a broken runner blocks every workflow.
- Wrong CPU architecture: build `linux/amd64` explicitly, otherwise the image pulls but never becomes active.

## Knowledge base maintenance

The files in `knowledge/` are copied into the image and sent to the model with every request (about 60 KB in total at most; larger files are left out and reported by `/healthz`). `azure-assets.md` is generated by `scripts/generate-asset-inventory.ps1`; never edit it by hand. Other files are hand-written. A file may declare extra scope words with a scope comment on its first line. Pushing a change under `knowledge/**` redeploys the agent automatically.
