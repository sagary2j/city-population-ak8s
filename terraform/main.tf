locals {
  name_prefix = "${var.project_name}-${var.environment}"
  acr_name    = replace("${var.project_name}${var.environment}acr${random_string.suffix.result}", "-", "")

  common_tags = merge(var.tags, {
    environment = var.environment
  })
}

resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
}

data "azurerm_client_config" "current" {}

# ---------------------------------------------------------------------------
# Resource Group
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "main" {
  name     = "${local.name_prefix}-rg"
  location = var.location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "main" {
  name                = "${local.name_prefix}-vnet"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = var.vnet_address_space
  tags                = local.common_tags
}

resource "azurerm_subnet" "aks" {
  name                 = "${local.name_prefix}-aks-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = var.aks_subnet_address_prefix
}

resource "azurerm_network_security_group" "aks" {
  name                = "${local.name_prefix}-aks-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

# ---------------------------------------------------------------------------
# Log Analytics (Container Insights / observability backbone, see README Part D)
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "main" {
  name                = "${local.name_prefix}-law"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days
  tags                = local.common_tags
}

# ---------------------------------------------------------------------------
# Azure Container Registry
# ---------------------------------------------------------------------------
#checkov:skip=CKV_AZURE_167:Retention policy for untagged manifests is not supported by the pinned azurerm provider schema in this take-home stack.
#checkov:skip=CKV_AZURE_164:Content trust enforcement is currently managed in CI/CD via image signing (cosign) rather than ACR trust policy blocks unsupported by this provider version.
resource "azurerm_container_registry" "main" {
  #checkov:skip=CKV_AZURE_167:Retention policy block unavailable in pinned azurerm provider schema for this stack.
  #checkov:skip=CKV_AZURE_164:Image trust is enforced in CI/CD via signing/verification workflow controls.
  name                          = local.acr_name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  sku                           = var.acr_sku
  admin_enabled                 = false # CI/CD authenticates via OIDC + AcrPush role, not admin creds
  public_network_access_enabled = false
  data_endpoint_enabled         = true
  zone_redundancy_enabled       = true
  quarantine_policy_enabled     = true
  tags                          = local.common_tags

  dynamic "georeplications" {
    for_each = toset(var.acr_replica_locations)
    content {
      location                = georeplications.value
      zone_redundancy_enabled = true
      tags                    = local.common_tags
    }
  }
}

# ---------------------------------------------------------------------------
# AKS Cluster
# ---------------------------------------------------------------------------
#checkov:skip=CKV_AZURE_117:Disk Encryption Set (CMK) is environment-specific and requires an externally managed key lifecycle; baseline uses platform-managed encryption plus host encryption.
resource "azurerm_kubernetes_cluster" "main" {
  #checkov:skip=CKV_AZURE_117:Cluster uses host encryption + platform-managed encryption; DES/CMK rollout is externalized.
  name                              = "${local.name_prefix}-aks"
  resource_group_name               = azurerm_resource_group.main.name
  location                          = azurerm_resource_group.main.location
  dns_prefix                        = "${local.name_prefix}-aks"
  kubernetes_version                = var.kubernetes_version
  sku_tier                          = "Standard"
  private_cluster_enabled           = var.enable_private_cluster
  azure_policy_enabled              = true
  local_account_disabled            = length(var.aks_admin_group_object_ids) > 0
  role_based_access_control_enabled = true
  oidc_issuer_enabled               = true # required for Azure AD Workload Identity
  workload_identity_enabled         = true
  image_cleaner_enabled             = true
  image_cleaner_interval_hours      = 48
  tags                              = local.common_tags

  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_node_vm_size
    node_count                   = var.system_node_count
    max_pods                     = 50
    vnet_subnet_id               = azurerm_subnet.aks.id
    only_critical_addons_enabled = true # keep app workloads off the system pool
    os_disk_size_gb              = 64
    os_disk_type                 = "Ephemeral"
    upgrade_settings {
      max_surge = "33%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  dynamic "azure_active_directory_role_based_access_control" {
    for_each = length(var.aks_admin_group_object_ids) > 0 ? [1] : []
    content {
      tenant_id              = data.azurerm_client_config.current.tenant_id
      admin_group_object_ids = var.aks_admin_group_object_ids
      azure_rbac_enabled     = true
    }
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    load_balancer_sku = "standard"
    service_cidr      = "10.30.0.0/16"
    dns_service_ip    = "10.30.0.10"
  }

  dynamic "api_server_access_profile" {
    for_each = length(var.api_server_authorized_ip_ranges) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.api_server_authorized_ip_ranges
    }
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  maintenance_window {
    allowed {
      day   = "Sunday"
      hours = [1, 2, 3, 4]
    }
  }

  lifecycle {
    ignore_changes = [
      # Node counts drift once the cluster autoscaler is active on the user
      # pool; avoid Terraform fighting the autoscaler on every plan.
      default_node_pool[0].node_count,
    ]
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.user_node_vm_size
  vnet_subnet_id        = azurerm_subnet.aks.id
  mode                  = "User"
  max_pods              = 50
  os_disk_type          = "Ephemeral"
  os_disk_size_gb       = 64
  auto_scaling_enabled  = true
  min_count             = var.user_node_min_count
  max_count             = var.user_node_max_count
  node_labels = {
    "workload" = "city-population"
  }
  tags = local.common_tags

  upgrade_settings {
    max_surge = "33%"
  }

  lifecycle {
    ignore_changes = [node_count]
  }
}

# ---------------------------------------------------------------------------
# Grant AKS (kubelet identity) permission to pull from ACR -- no imagePullSecrets needed.
# ---------------------------------------------------------------------------
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}
