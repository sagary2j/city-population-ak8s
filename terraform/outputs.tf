output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "aks_oidc_issuer_url" {
  description = "Used when configuring Azure AD Workload Identity federated credentials for in-cluster workloads."
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "acr_login_server" {
  description = "Feed this into helm/values.yaml's app.image.repository and the GitHub Actions workflow's IMAGE_NAME."
  value       = azurerm_container_registry.main.login_server
}

output "acr_name" {
  value = azurerm_container_registry.main.name
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.main.id
}

output "key_vault_name" {
  value = var.enable_key_vault ? azurerm_key_vault.main[0].name : null
}

output "github_actions_client_id" {
  description = "Set this as the AZURE_CLIENT_ID secret/variable in the GitHub repo for OIDC login (azure/login@v2)."
  value       = var.create_github_oidc_identity ? azuread_application.github_actions[0].client_id : null
}

output "github_actions_tenant_id" {
  description = "Set this as the AZURE_TENANT_ID secret/variable in the GitHub repo."
  value       = var.create_github_oidc_identity ? data.azurerm_client_config.current.tenant_id : null
}

output "github_actions_subscription_id" {
  description = "Set this as the AZURE_SUBSCRIPTION_ID secret/variable in the GitHub repo."
  value       = var.create_github_oidc_identity ? data.azurerm_client_config.current.subscription_id : null
}

output "get_credentials_command" {
  value = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name} --overwrite-existing"
}
