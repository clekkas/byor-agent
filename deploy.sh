#!/usr/bin/env bash
# Deploy the hosted agent with Terraform (AzAPI) from a workstation.
#
# The Foundry<->JFrog registry connection is platform-owned (foundation repo) and only consumed
# here. Connection name and project endpoint come from the published platform contract
# (foundry-<env>.json, needs jq) or from explicit env vars. Foundation state is never read.
#
#   IMAGE=<host>/<repo>/agent@sha256:<digest> CONTRACT_FILE=./foundry-dev.json ./deploy.sh
#   AUTO_APPROVE=1 ... ./deploy.sh     # non-interactive
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_TF_DIR="${ROOT}/infra/hosted-agent"
AGENT_SERVICE="${AGENT_SERVICE:-private-registry-agent}"
MODEL_DEPLOYMENT="${MODEL_DEPLOYMENT:-gpt-5-mini}"

if [[ -n "${CONTRACT_FILE:-}" ]]; then
  [[ -f "${CONTRACT_FILE}" ]] || { echo "Contract file not found: ${CONTRACT_FILE}" >&2; exit 1; }
  PROJECT_ENDPOINT="${PROJECT_ENDPOINT:-$(jq -r '.values.FOUNDRY_PROJECT_ENDPOINT // empty' "${CONTRACT_FILE}")}"
  REGISTRY_CONNECTION_NAME="${REGISTRY_CONNECTION_NAME:-$(jq -r '.values.JFROG_REGISTRY_CONNECTION_NAME // empty' "${CONTRACT_FILE}")}"
fi
[[ -n "${PROJECT_ENDPOINT:-}" ]] || { echo "Project endpoint unknown. Set CONTRACT_FILE or PROJECT_ENDPOINT." >&2; exit 1; }
[[ -n "${REGISTRY_CONNECTION_NAME:-}" ]] || { echo "Registry connection name unknown. Set CONTRACT_FILE or REGISTRY_CONNECTION_NAME." >&2; exit 1; }
[[ "${IMAGE:-}" =~ ^[^/]+/.+@sha256:[0-9a-f]{64}$ ]] || {
  echo "IMAGE must be digest-pinned (<host>/<repo>/<image>@sha256:<64 hex>), got '${IMAGE:-}'." >&2
  exit 1
}
[[ -f "${AGENT_TF_DIR}/backend.hcl" ]] || {
  echo "Missing ${AGENT_TF_DIR}/backend.hcl (remote state). Run scripts/bootstrap-github-oidc.ps1 first." >&2
  exit 1
}

echo "==> Terraform: hosted agent ${AGENT_SERVICE} (connection: ${REGISTRY_CONNECTION_NAME})"
terraform -chdir="${AGENT_TF_DIR}" init -input=false -backend-config=backend.hcl
terraform -chdir="${AGENT_TF_DIR}" plan -input=false -out=tfplan \
  -var="project_endpoint=${PROJECT_ENDPOINT}" \
  -var="agent_name=${AGENT_SERVICE}" \
  -var="image_uri=${IMAGE}" \
  -var="registry_connection_name=${REGISTRY_CONNECTION_NAME}" \
  -var="model_deployment_name=${MODEL_DEPLOYMENT}" \
  -var="import_existing_agent=true"
if [[ "${AUTO_APPROVE:-0}" != "1" ]]; then
  read -r -p "Apply the hosted-agent plan? (y/N) " answer
  [[ "${answer}" =~ ^([yY]|[yY][eE][sS])$ ]] || { echo "Aborted."; exit 1; }
fi
terraform -chdir="${AGENT_TF_DIR}" apply -input=false tfplan
rm -f "${AGENT_TF_DIR}/tfplan"
echo "Hosted agent version: $(terraform -chdir="${AGENT_TF_DIR}" output -raw agent_version)"
