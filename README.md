# BYOR hosted agent — Step 1 container

Minimal Foundry hosted agent image for the "bring your own registry" (JFrog + OIDC) walkthrough.

## Files

| File | Purpose |
|---|---|
| `app.py` | FastAPI app serving `POST /responses` (Responses protocol) and `GET /healthz` |
| `Dockerfile` | `linux/amd64`, python:3.12-slim, non-root uid 10001, listens on `$PORT` (8088) |
| `requirements.txt` | fastapi + uvicorn; openai + azure-identity only needed for model mode |
| `build-and-push.sh` | Build → local smoke test → push to JFrog |
| `infra/registry-connection/` | Terraform (AzAPI) for the Foundry project registry connection; remote state in Azure Storage |
| `deploy.ps1` / `deploy.sh` | `terraform apply` the registry connection, then `azd deploy` the agent (needs network access to the state account) |
| `.github/workflows/deploy-agent.yml` | CI/CD: build → push to JFrog → Terraform → `azd deploy` → smoke test |
| `scripts/bootstrap-github-oidc.ps1` | One-time: Entra app + GitHub OIDC credential, RBAC, state storage, repo variables |
| `infra/ci-runner/` + `scripts/setup-runner.ps1` | Self-hosted runner VM in a VNet with a private endpoint to the state account |

## Modes

- **Echo mode (default).** No model call. Proves Foundry exchanged the OIDC token, pulled the image from JFrog, and started the container. Use this for the first deploy — it isolates the registry plumbing from everything else.
- **Model mode.** Set `AZURE_AI_MODEL_DEPLOYMENT_NAME` and `AZURE_OPENAI_ENDPOINT` in the agent's `env` map and the agent relays to that deployment using the runtime managed identity. No keys in the image.

## Run it

```bash
export JFROG_HOST="yourtrial.jfrog.io"
export JFROG_REPO="foundry-agents"
export IMAGE_TAG="0.1"

docker login "$JFROG_HOST"
./build-and-push.sh
```

Local check, if you want it by hand:

```bash
docker run --rm -p 8088:8088 "$JFROG_HOST/$JFROG_REPO/agent:0.1"
curl localhost:8088/healthz
curl -X POST localhost:8088/responses -H 'Content-Type: application/json' \
  -d '{"input":"Respond with a short deployment confirmation."}'
```

Expected: a JSON envelope with `status: "completed"` and an `output_text` field.

## Then

### Registry connection (Terraform + AzAPI)

The `private-registry` connection is managed by Terraform instead of `azd ai connection create`. It's the same `CustomKeys` connection (`type=registry_connection`, `mode=oauth_token_exchange`) with `audience`, `tokenEndpoint` and `body.provider_name` keys.

```bash
cd infra/registry-connection
cp terraform.tfvars.example terraform.tfvars   # fill in project + JFrog OIDC values
az login
terraform init -backend-config=backend.hcl     # backend.hcl is written by scripts/bootstrap-github-oidc.ps1
terraform apply
```

- Requires Terraform >= 1.7 and the Azure CLI login (AzAPI uses it for auth).
- State lives in Azure Storage (`backend "azurerm"`, Entra auth). The account's public network access is disabled by subscription policy, so `init` only works from a network that can reach its private endpoint, such as the CI runner. Normally you run this through the pipeline.
- `connection_name` must match `registryConnectionId` in `azure.yaml`.
- If the connection already exists, set `import_existing_connection = true` and the first apply adopts it. The first apply after import shows an in-place update because ARM never returns connection credentials; it re-sends the same keys.
- Output `project_principal_id` is the identity to bind in the JFrog OIDC identity mapping.

### Agent

Deploy the agent with azd as before (the connection is no longer created by azd):

```bash
azd deploy private-registry-agent
```

Or run both steps with `./deploy.ps1` (`-AutoApprove`, `-SkipAgentDeploy`) or `./deploy.sh` (`AUTO_APPROVE=1`, `SKIP_AGENT_DEPLOY=1`).

For a new agent, generate `azure.yaml` with:

```bash
azd ai agent init --no-prompt \
  --agent-name private-registry-agent \
  --image yourtrial.jfrog.io/foundry-agents/agent:0.1 \
  --project-id "$PROJECT_ID" \
  --registry-connection private-registry
```

Keep `docker.imagePassthrough: true` and `registryConnectionId: private-registry` in the generated `azure.yaml`, and leave the existing connection out of the `uses` list.

## CI/CD (GitHub Actions)

`.github/workflows/deploy-agent.yml` runs on push to `main` (app, Dockerfile, `azure.yaml`, `infra/**`) and on manual dispatch. No secrets are stored; every login uses OIDC.

| Job | Runner | Steps |
|---|---|---|
| `build` | `ubuntu-latest` | JFrog login (GitHub OIDC) → `docker build` linux/amd64 → container smoke test (`/readiness`, `/liveness`, `POST /responses`) → push `agent:sha-<commit>` |
| `deploy` | self-hosted (`byor-private`) | Azure login (GitHub OIDC) → `terraform apply` registry connection (remote state) → `azd deploy` with the new image → `azd ai agent invoke` smoke test |

Manual dispatch accepts `image_tag` to redeploy an existing image without building.

### One-time setup

1. `./scripts/bootstrap-github-oidc.ps1`. Creates the `github-byor-agent-deployer` Entra app with a federated credential for `repo:clekkas/byor-agent:ref:refs/heads/main`. It also creates role assignments (Foundry Project Manager on the project, Reader on the resource group, Storage Blob Data Contributor on state), the state storage account and container, and all repo variables. Values come from the azd environment and `terraform.tfvars`.
2. `./scripts/setup-runner.ps1 -Location swedencentral`. Uses Terraform (AzAPI, local state) to create a VNet, a private endpoint and DNS for the state account, and an Ubuntu VM without a public IP or inbound access. It then registers the VM as a repo runner through `az vm run-command`.
3. In JFrog, add an OpenID Connect integration for GitHub:
   - Provider type `GitHub`, name `github-oidc`, provider URL `https://token.actions.githubusercontent.com`.
   - Identity mapping claims `{"repository":"clekkas/byor-agent","ref":"refs/heads/main"}`, scoped to a group or user with Read + Deploy/Cache on `byor-demo-docker`.

### Notes

- **Why a self-hosted runner:** a subscription policy forces `publicNetworkAccess=Disabled` on storage accounts, so GitHub-hosted runners can't reach Terraform state.
- **Runner outbound access:** the subscription can't create public IPs, so the runner subnet uses Azure default outbound access instead of a NAT gateway.
- **Image tag:** the workflow rewrites the `image:` line in `azure.yaml` on the runner only. The committed tag is just the local default.

## Caveats

- The Microsoft Learn BYOR article specifies the protocol name and version (`responses` / `2.0.0`) but not the full request/response wire contract for a self-built container. The envelope here follows the standard Responses shape (`output[].content[].output_text` plus the `output_text` convenience field) and accepts `input` as either a plain string or a message array. If Foundry's invoke returns a protocol error, capture the actual request body it sends and adjust `create_response` — the pull path is unaffected.
- Build `linux/amd64` explicitly. On Apple silicon the wrong arch pulls fine and then never reaches Active.
- Pinned dependency versions are a starting point — bump before anything customer-facing.
