# Enables the GitHub Actions workflows in .github/workflows/ to authenticate
# to Azure via OIDC (azure/login@v2 with no client secret / long-lived
# credential stored in GitHub). Trust is scoped to a specific repo + branch/
# environment via the federated credential's `subject` claim, which GitHub's
# OIDC token issuer populates.

resource "azuread_application" "github_actions" {
  count = var.create_github_oidc_identity ? 1 : 0

  display_name = "${local.name_prefix}-github-actions"
  tags         = ["terraform", "github-actions", var.environment]
}

resource "azuread_service_principal" "github_actions" {
  count = var.create_github_oidc_identity ? 1 : 0

  client_id = azuread_application.github_actions[0].client_id
  tags      = ["terraform", "github-actions", var.environment]
}

# GitHub now issues immutable `sub` claims for this repository (owner/repo
# numeric IDs embedded, format `repo:OWNER@OWNER_ID/REPO@REPO_ID:...`) instead
# of the legacy `repo:owner/repo:...` format. See var.github_owner_id /
# var.github_repo_id for how to look these values up.
locals {
  github_immutable_repo = "${split("/", var.github_repository)[0]}@${var.github_owner_id}/${split("/", var.github_repository)[1]}@${var.github_repo_id}"
}

# One federated credential per allowed GitHub Environment (e.g. dev, prod --
# matches the `environment:` key in the deploy job of ci-cd.yaml), plus one
# for direct pushes to the default branch (used by the Terraform plan/apply
# workflow, which does not run inside a GitHub Environment).
resource "azuread_application_federated_identity_credential" "github_environments" {
  for_each = var.create_github_oidc_identity ? toset(var.github_oidc_environments) : []

  application_id = azuread_application.github_actions[0].id
  display_name   = "github-env-${each.value}"
  description    = "Trusts GitHub Actions runs deployed under the '${each.value}' Environment."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${local.github_immutable_repo}:environment:${each.value}"
}

resource "azuread_application_federated_identity_credential" "github_default_branch" {
  count = var.create_github_oidc_identity ? 1 : 0

  application_id = azuread_application.github_actions[0].id
  display_name   = "github-branch-${var.github_default_branch}"
  description    = "Trusts GitHub Actions runs triggered from the default branch (e.g. Terraform plan/apply)."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${local.github_immutable_repo}:ref:refs/heads/${var.github_default_branch}"
}

resource "azuread_application_federated_identity_credential" "github_pull_requests" {
  count = var.create_github_oidc_identity ? 1 : 0

  application_id = azuread_application.github_actions[0].id
  display_name   = "github-pull-requests"
  description    = "Trusts GitHub Actions runs on pull_request events (for `terraform plan` on PRs)."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${local.github_immutable_repo}:pull_request"
}

# --- Least-privilege role assignments for the CI/CD identity ---------------

# Push (and pull) images to ACR.
resource "azurerm_role_assignment" "github_acr_push" {
  count = var.create_github_oidc_identity ? 1 : 0

  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPush"
  principal_id         = azuread_service_principal.github_actions[0].object_id
}

# Read cluster credentials to run `helm`/`kubectl`/`argocd` commands against
# AKS (e.g. bootstrapping the ArgoCD Application on first deploy).
resource "azurerm_role_assignment" "github_aks_cluster_user" {
  count = var.create_github_oidc_identity ? 1 : 0

  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azuread_service_principal.github_actions[0].object_id
}

# Read/write the Terraform remote state blob (terraform init/plan/apply in
# CI authenticate to the azurerm backend via this SP's OIDC token, so it
# needs data-plane access to the state container). Pair with
# -backend-config="use_azuread_auth=true" in the workflow's `terraform init`.
data "azurerm_storage_account" "tfstate" {
  name                = var.tfstate_storage_account_name
  resource_group_name = var.tfstate_resource_group_name
}

resource "azurerm_role_assignment" "github_tfstate_access" {
  count = var.create_github_oidc_identity ? 1 : 0

  scope                = data.azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.github_actions[0].object_id
}

# NOTE: intentionally NOT granted Contributor on the resource group. The
# Terraform plan/apply workflow needs broader (Contributor + User Access
# Administrator, scoped to this resource group) permissions to manage
# infrastructure; grant that separately and only to the workflow/environment
# that runs `terraform apply`, keeping the app build/deploy identity minimal.
