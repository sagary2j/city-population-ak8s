#!/usr/bin/env bash
# Creates the resource group, storage account, and blob container that hold
# Terraform remote state - this can't itself be managed by the Terraform it
# bootstraps (classic chicken-and-egg), so it's a small idempotent script run
# once per Azure subscription/environment before `terraform init`.

# Usage:
#   ./scripts/bootstrap-tfstate.sh <environment> [location]
#   ./scripts/bootstrap-tfstate.sh dev westeurope

set -euo pipefail

ENVIRONMENT="${1:?Usage: $0 <environment> [location]}"
LOCATION="${2:-eastus}"
PROJECT="citypop"

RG_NAME="${PROJECT}-${ENVIRONMENT}-tfstate-rg"
# Storage account names: 3-24 chars, lowercase alphanumeric only.
SA_NAME="${PROJECT}${ENVIRONMENT}tfstate$(date +%s | tail -c 5)"
CONTAINER_NAME="tfstate"

echo "==> Ensuring resource group '${RG_NAME}' exists in ${LOCATION}"
az group create --name "${RG_NAME}" --location "${LOCATION}" --output none

# Reuse an existing storage account for this env/purpose if one is already tagged as such,
# instead of creating a new one on every run.
EXISTING_SA=$(az storage account list \
  --resource-group "${RG_NAME}" \
  --query "[?tags.purpose=='tfstate'].name | [0]" \
  --output tsv || true)

if [[ -n "${EXISTING_SA}" ]]; then
  echo "==> Reusing existing storage account '${EXISTING_SA}'"
  SA_NAME="${EXISTING_SA}"
else
  echo "==> Creating storage account '${SA_NAME}'"
  az storage account create \
    --name "${SA_NAME}" \
    --resource-group "${RG_NAME}" \
    --location "${LOCATION}" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --https-only true \
    --tags purpose=tfstate environment="${ENVIRONMENT}" \
    --output none
fi

echo "==> Ensuring blob container '${CONTAINER_NAME}' exists"
az storage container create \
  --name "${CONTAINER_NAME}" \
  --account-name "${SA_NAME}" \
  --auth-mode login \
  --output none

cat <<EOF

Bootstrap complete. Initialize Terraform with:

  cd terraform
  terraform init \\
    -backend-config="resource_group_name=${RG_NAME}" \\
    -backend-config="storage_account_name=${SA_NAME}" \\
    -backend-config="container_name=${CONTAINER_NAME}" \\
    -backend-config="key=city-population/${ENVIRONMENT}.tfstate"

Store these four values as GitHub Actions repo/environment variables
(TF_STATE_RG, TF_STATE_SA, TF_STATE_CONTAINER, TF_STATE_KEY) so the
terraform.yaml workflow can init the same backend non-interactively.
EOF
