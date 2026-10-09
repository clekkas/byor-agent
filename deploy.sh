#!/usr/bin/env bash
# Provision the Foundry registry connection and hosted agent with Terraform (AzAPI).
#
#   ./deploy.sh                    # plan, prompt, apply, azd deploy
#   AUTO_APPROVE=1 ./deploy.sh     # non-interactive
#   SKIP_AGENT_DEPLOY=1 ./deploy.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${ROOT}/infra/registry-connection"
AGENT_TF_DIR="${ROOT}/infra/hosted-agent"
AGENT_SERVICE="${AGENT_SERVICE:-private-registry-agent}"

[[ -f "${TF_DIR}/terraform.tfvars" ]] || {
  echo "Missing ${TF_DIR}/terraform.tfvars. Copy terraform.tfvars.example and fill it in." >&2
  exit 1
}
[[ -f "${TF_DIR}/backend.hcl" ]] || {
  echo "Missing ${TF_DIR}/backend.hcl (remote state). Run scripts/bootstrap-github-oidc.ps1 first." >&2
  exit 1
}
echo "==> Terraform: registry connection (AzAPI)"
terraform -chdir="${TF_DIR}" init -input=false -backend-config=backend.hcl
terraform -chdir="${TF_DIR}" plan -input=false -out=tfplan
if [[ "${AUTO_APPROVE:-0}" != "1" ]]; then
  read -r -p "Apply this plan? (y/N) " answer
  [[ "${answer}" =~ ^([yY]|[yY][eE][sS])$ ]] || { echo "Aborted."; exit 1; }
fi
terraform -chdir="${TF_DIR}" apply -input=false tfplan
rm -f "${TF_DIR}/tfplan"

CONNECTION_NAME="$(terraform -chdir="${TF_DIR}" output -raw registry_connection_name)"
PRINCIPAL_ID="$(terraform -chdir="${TF_DIR}" output -raw project_principal_id)"
echo "Registry connection: ${CONNECTION_NAME}"
echo "Project identity (bind in JFrog OIDC identity mapping): ${PRINCIPAL_ID}"

grep -Eq "registryConnectionId:[[:space:]]*[\"']?${CONNECTION_NAME}[\"']?[[:space:]]*$" "${ROOT}/azure.yaml" || {
  echo "azure.yaml registryConnectionId does not match Terraform connection '${CONNECTION_NAME}'." >&2
  exit 1
}

[[ "${SKIP_AGENT_DEPLOY:-0}" == "1" ]] && exit 0

[[ -f "${AGENT_TF_DIR}/backend.hcl" ]] || {
  echo "Missing ${AGENT_TF_DIR}/backend.hcl (remote state). Run scripts/bootstrap-github-oidc.ps1 first." >&2
  exit 1
}

IMAGE="${IMAGE:-$(sed -nE \
  -e 's/^[[:space:]]*image:[[:space:]]*"([^"]+)"[[:space:]]*$/\1/p' \
  -e 's/^[[:space:]]*image:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' \
  "${ROOT}/azure.yaml" | head -n 1)}"
PROJECT_ENDPOINT="${PROJECT_ENDPOINT:-$(sed -nE 's|^[[:space:]]*endpoint:[[:space:]]*(https://[^[:space:]]+)[[:space:]]*$|\1|p' "${ROOT}/azure.yaml" | head -n 1)}"
MODEL_DEPLOYMENT="${MODEL_DEPLOYMENT:-gpt-5-mini}"
[[ -n "${IMAGE}" ]] || { echo "Unable to read the image from azure.yaml; set IMAGE." >&2; exit 1; }
[[ -n "${PROJECT_ENDPOINT}" ]] || { echo "Unable to read the project endpoint from azure.yaml; set PROJECT_ENDPOINT." >&2; exit 1; }

echo "==> Terraform: hosted agent ${AGENT_SERVICE}"
terraform -chdir="${AGENT_TF_DIR}" init -input=false -backend-config=backend.hcl
terraform -chdir="${AGENT_TF_DIR}" plan -input=false -out=tfplan \
  -var="project_endpoint=${PROJECT_ENDPOINT}" \
  -var="agent_name=${AGENT_SERVICE}" \
  -var="image_uri=${IMAGE}" \
  -var="registry_connection_name=${CONNECTION_NAME}" \
  -var="model_deployment_name=${MODEL_DEPLOYMENT}" \
  -var="import_existing_agent=true"
if [[ "${AUTO_APPROVE:-0}" != "1" ]]; then
  read -r -p "Apply the hosted-agent plan? (y/N) " answer
  [[ "${answer}" =~ ^([yY]|[yY][eE][sS])$ ]] || { echo "Aborted."; exit 1; }
fi
terraform -chdir="${AGENT_TF_DIR}" apply -input=false tfplan
rm -f "${AGENT_TF_DIR}/tfplan"
echo "Hosted agent version: $(terraform -chdir="${AGENT_TF_DIR}" output -raw agent_version)"
