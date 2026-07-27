# Backs the "replace the Helm Secret with Key Vault" recommendation in
# README.md Part D. The AKS-managed identity created by the
# key_vault_secrets_provider add-on (main.tf) is granted read access here;
# application Pods consume secrets via a SecretProviderClass (see
# helm/templates/secretproviderclass.yaml) using Azure AD Workload Identity
# rather than any static credential.

resource "azurerm_key_vault" "main" {
  count = var.enable_key_vault ? 1 : 0

  name                       = "${substr(local.name_prefix, 0, 17)}-kv-${random_string.suffix.result}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = var.environment == "prod"
  soft_delete_retention_days = 7
  enable_rbac_authorization  = true
  tags                       = local.common_tags

  network_acls {
    default_action = "Allow" # tighten to "Deny" + service endpoints for production, see README Part D
    bypass         = "AzureServices"
  }
}

# The AKS add-on identity used by the CSI Secrets Store driver to read secrets.
resource "azurerm_role_assignment" "aks_kv_secrets_reader" {
  count = var.enable_key_vault ? 1 : 0

  scope                = azurerm_key_vault.main[0].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_kubernetes_cluster.main.key_vault_secrets_provider[0].secret_identity[0].object_id
}

# Terraform's own identity gets Secrets Officer so it (or an operator) can
# seed the initial ES credentials. In steady state, rotate these via a
# separate, access-controlled process -- not via `terraform apply` on every run.
resource "azurerm_role_assignment" "terraform_kv_admin" {
  count = var.enable_key_vault ? 1 : 0

  scope                = azurerm_key_vault.main[0].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}
