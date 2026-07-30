#!/usr/bin/env bash
# Idempotently installs ArgoCD on the (possibly fully private) AKS cluster
# provisioned by terraform/, registers this repo's argocd/project.yaml +
# argocd/application.yaml, and optionally exposes the ArgoCD UI via a public
# LoadBalancer restricted to specific source IPs.
#
# Why `az aks command invoke` everywhere: when terraform/dev.tfvars has
# enable_private_cluster=true and api_server_authorized_ip_ranges=[], the AKS
# API server has NO public/direct access path at all - not even from a
# correctly-configured local kubectl. `az aks command invoke` runs kubectl
# inside the cluster via the ARM control plane and streams back stdout,
# which works regardless of network reachability, as long as the cluster is
# Running and the caller has Microsoft.ContainerService/managedClusters/
# runCommand/action (covered by Contributor on the resource group).
#
# Usage:
#   ./scripts/bootstrap-argocd.sh <resource-group> <cluster-name> [options]
#
# Options:
#   --expose-ui <cidr>   Patch argocd-server to type=LoadBalancer with
#                         loadBalancerSourceRanges=[<cidr>] (e.g. 203.0.113.4/32).
#                         Requires a matching NSG rule - set
#                         argocd_ui_allowed_cidrs in terraform/dev.tfvars to
#                         the same CIDR and `terraform apply` BEFORE running
#                         this, or the LB will time out (Service-level and
#                         NSG-level allow both have to agree).
#   --hide-ui             Reverts argocd-server back to type=ClusterIP.
#   --repo-url <url>      Override the repoURL patched into project.yaml /
#                         application.yaml before applying (defaults to the
#                         repoURL already committed in those files).
#   --revision <ref>       Override targetRevision (branch/tag/sha) before
#                         applying (defaults to what's committed in
#                         application.yaml).
#
# Examples:
#   ./scripts/bootstrap-argocd.sh citypop-dev-rg citypop-dev-aks
#   ./scripts/bootstrap-argocd.sh citypop-dev-rg citypop-dev-aks --expose-ui 203.0.113.4/32
#   ./scripts/bootstrap-argocd.sh citypop-dev-rg citypop-dev-aks --hide-ui
#   ./scripts/bootstrap-argocd.sh citypop-dev-rg citypop-dev-aks --revision feature/build-deploy-acr

set -euo pipefail

RESOURCE_GROUP="${1:?Usage: $0 <resource-group> <cluster-name> [--expose-ui <cidr>|--hide-ui] [--repo-url <url>] [--revision <ref>]}"
CLUSTER_NAME="${2:?Usage: $0 <resource-group> <cluster-name> [--expose-ui <cidr>|--hide-ui] [--repo-url <url>] [--revision <ref>]}"
shift 2

EXPOSE_CIDR=""
HIDE_UI=false
REPO_URL_OVERRIDE=""
REVISION_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expose-ui)
      EXPOSE_CIDR="${2:?--expose-ui requires a CIDR, e.g. 203.0.113.4/32}"
      shift 2
      ;;
    --hide-ui)
      HIDE_UI=true
      shift
      ;;
    --repo-url)
      REPO_URL_OVERRIDE="${2:?--repo-url requires a value}"
      shift 2
      ;;
    --revision)
      REVISION_OVERRIDE="${2:?--revision requires a value}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARGOCD_DIR="${REPO_ROOT}/argocd"

invoke() {
  # $1 = command string, remaining args = --file paths to attach
  local cmd="$1"
  shift
  local file_args=()
  for f in "$@"; do
    file_args+=(--file "$f")
  done
  az aks command invoke \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --command "${cmd}" \
    "${file_args[@]}"
}

echo "==> Verifying cluster '${CLUSTER_NAME}' is running"
POWER_STATE=$(az aks show -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --query "powerState.code" -o tsv)
if [[ "${POWER_STATE}" != "Running" ]]; then
  echo "==> Cluster is '${POWER_STATE}', starting it..."
  az aks start -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --output none
fi
az aks wait -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --created --custom "powerState.code=='Running'" --timeout 600
for _ in $(seq 1 30); do
  PROVISIONING_STATE=$(az aks show -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --query "provisioningState" -o tsv)
  [[ "${PROVISIONING_STATE}" == "Succeeded" ]] && break
  sleep 10
done
if [[ "${PROVISIONING_STATE}" != "Succeeded" ]]; then
  echo "Cluster did not reach provisioningState=Succeeded in time (last seen: ${PROVISIONING_STATE})" >&2
  exit 1
fi

if [[ "${HIDE_UI}" == "true" ]]; then
  echo "==> Reverting argocd-server Service to ClusterIP"
  invoke "kubectl -n argocd patch svc argocd-server -p '{\"spec\":{\"type\":\"ClusterIP\",\"loadBalancerSourceRanges\":null}}'"
  echo "==> Done."
  exit 0
fi

echo "==> Installing/upgrading ArgoCD (server-side apply avoids the ApplicationSet CRD annotation-size limit)"
invoke "kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - && kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

echo "==> Waiting for argocd-server rollout"
invoke "kubectl -n argocd rollout status deployment/argocd-server --timeout=300s"

# Apply optional repoURL/targetRevision overrides to local temp copies so the
# committed argocd/*.yaml files aren't mutated by this script.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
cp "${ARGOCD_DIR}/project.yaml" "${TMP_DIR}/project.yaml"
cp "${ARGOCD_DIR}/application.yaml" "${TMP_DIR}/application.yaml"

if [[ -n "${REPO_URL_OVERRIDE}" ]]; then
  sed -i.bak "s#repoURL:.*#repoURL: ${REPO_URL_OVERRIDE}#" "${TMP_DIR}/project.yaml" "${TMP_DIR}/application.yaml"
fi
if [[ -n "${REVISION_OVERRIDE}" ]]; then
  sed -i.bak "s#targetRevision:.*#targetRevision: ${REVISION_OVERRIDE}#" "${TMP_DIR}/application.yaml"
fi
rm -f "${TMP_DIR}"/*.bak

echo "==> Applying argocd/project.yaml and argocd/application.yaml"
invoke "kubectl apply -f project.yaml -f application.yaml" "${TMP_DIR}/project.yaml" "${TMP_DIR}/application.yaml"

if [[ -n "${EXPOSE_CIDR}" ]]; then
  echo "==> Exposing argocd-server via public LoadBalancer restricted to ${EXPOSE_CIDR}"
  echo "    (requires terraform/dev.tfvars argocd_ui_allowed_cidrs to include the same CIDR, applied beforehand)"
  invoke "kubectl -n argocd patch svc argocd-server -p '{\"spec\":{\"type\":\"LoadBalancer\",\"loadBalancerSourceRanges\":[\"${EXPOSE_CIDR}\"]}}'"
  echo "==> Waiting for external IP..."
  invoke "for i in \$(seq 1 24); do IP=\$(kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); if [ -n \"\$IP\" ]; then echo EXTERNAL_IP=\$IP; break; fi; sleep 5; done"
  echo "==> Admin password (rotate after first login):"
  invoke "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
fi

echo "==> Checking Application sync/health status"
invoke "kubectl -n argocd get application city-population -o wide"

echo "==> Done."
