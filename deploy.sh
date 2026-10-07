#!/usr/bin/env bash
# Provision the Foundry registry connection with Terraform (AzAPI), then deploy
# the hosted agent with azd, exactly as before.
#
#   ./deploy.sh                    # plan, prompt, apply, azd deploy
#   AUTO_APPROVE=1 ./deploy.sh     # non-interactive
#   SKIP_AGENT_DEPLOY=1 ./deploy.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${ROOT}/infra/registry-connection"
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

echo "==> azd: deploying ${AGENT_SERVICE}"
cd "${ROOT}"
azd deploy "${AGENT_SERVICE}" --no-prompt
