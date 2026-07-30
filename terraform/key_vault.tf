# Optional Key Vault backing for app secrets. The AKS-managed identity from
# the key_vault_secrets_provider add-on (main.tf) gets read access here;
# Pods consume secrets via a SecretProviderClass (see
# helm/templates/secretproviderclass.yaml) using Workload Identity, not a static credential.

#checkov:skip=CKV2_AZURE_32:Private endpoint is implemented as a separate azurerm_private_endpoint resource with the same conditional count; this skip avoids graph-resolution false positives in CI.
#checkov:skip=CKV_AZURE_110:Purge protection is intentionally environment-gated (enabled only when environment=="prod") so this dev stack can be torn down immediately via `terraform destroy` without waiting out the soft-delete retention; production deployments get purge protection automatically.
resource "azurerm_key_vault" "main" {
  #checkov:skip=CKV2_AZURE_32:Private endpoint exists in this module (azurerm_private_endpoint.key_vault), but graph check can false-positive with conditional resources.
  #checkov:skip=CKV_AZURE_110:See resource-level skip above - purge protection is environment-gated by design.
  count                         = var.enable_key_vault ? 1 : 0
  name                          = "${substr(local.name_prefix, 0, 15)}-kv-${random_string.suffix.result}"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  purge_protection_enabled      = var.environment == "prod"
  soft_delete_retention_days    = 7
  rbac_authorization_enabled    = true
  public_network_access_enabled = false
  tags                          = local.common_tags

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}

resource "azurerm_private_dns_zone" "key_vault" {
  count = var.enable_key_vault ? 1 : 0

  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault" {
  count = var.enable_key_vault ? 1 : 0

  name                  = "${local.name_prefix}-kv-dns-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.key_vault[0].name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = local.common_tags
}

resource "azurerm_private_endpoint" "key_vault" {
  count = var.enable_key_vault ? 1 : 0

  name                = "${local.name_prefix}-kv-pe"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.aks.id
  tags                = local.common_tags

  private_service_connection {
    name                           = "${local.name_prefix}-kv-psc"
    private_connection_resource_id = azurerm_key_vault.main[0].id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.key_vault[0].id]
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
# separate, access-controlled process - not via `terraform apply` on every run.
#
# Pinned to explicit, static principals (rather than the dynamic "current
# caller" via data.azurerm_client_config.current.object_id) so this role
# assignment doesn't flip-flop (force a replace) every time a different
# identity - a human operator locally vs. the CI service principal in
# GitHub Actions - runs `terraform apply`.
resource "azurerm_role_assignment" "terraform_kv_admin" {
  count = var.enable_key_vault ? 1 : 0

  scope                = azurerm_key_vault.main[0].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.terraform_operator_object_id
}

resource "azurerm_role_assignment" "github_kv_admin" {
  count = var.enable_key_vault && var.create_github_oidc_identity ? 1 : 0

  scope                = azurerm_key_vault.main[0].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azuread_service_principal.github_actions[0].object_id
}
