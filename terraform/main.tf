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

# resource group
resource "azurerm_resource_group" "main" {
  name     = "${local.name_prefix}-rg"
  location = var.location
  tags     = local.common_tags
}

# networking
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

# Opens the ArgoCD UI LoadBalancer to specific CIDRs (see
# scripts/bootstrap-argocd.sh --expose-ui). The NSG default is
# deny-all-inbound-from-internet, so without this rule the LB's public IP
# never gets traffic even once the Service itself is configured. Only
# created when argocd_ui_allowed_cidrs is non-empty.
resource "azurerm_network_security_rule" "argocd_ui" {
  count                       = length(var.argocd_ui_allowed_cidrs) > 0 ? 1 : 0
  name                        = "AllowArgoCDUIInbound"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefixes     = var.argocd_ui_allowed_cidrs
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

# log analytics workspace (Container Insights)
resource "azurerm_log_analytics_workspace" "main" {
  name                = "${local.name_prefix}-law"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days
  tags                = local.common_tags
}

# container registry
#checkov:skip=CKV_AZURE_167:Retention policy for untagged manifests is not supported by the pinned azurerm provider schema used here.
#checkov:skip=CKV_AZURE_164:Content trust enforcement is currently managed in CI/CD via image signing (cosign) rather than ACR trust policy blocks unsupported by this provider version.
resource "azurerm_container_registry" "main" {
  #checkov:skip=CKV_AZURE_167:Retention policy block unavailable in pinned azurerm provider schema for this stack.
  #checkov:skip=CKV_AZURE_164:Image trust is enforced in CI/CD via signing/verification workflow controls.
  #checkov:skip=CKV_AZURE_137:Public network access is required so GitHub-hosted Actions runners (public IPs) can push/pull; access is still gated by AAD auth + RBAC (AcrPush), not anonymous.
  #checkov:skip=CKV_AZURE_139:Same as CKV_AZURE_137 - public networking is required for GitHub-hosted runners; access is gated by AAD auth + AcrPush RBAC.
  #checkov:skip=CKV_AZURE_166:Quarantine requires an external Defender for Cloud/Qualys scanner integration (not configured here) to ever release images; Trivy in ci-cd.yaml already gates vulnerabilities before push.
  name                          = local.acr_name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  sku                           = var.acr_sku
  admin_enabled                 = false # CI/CD authenticates via OIDC + AcrPush role, not admin creds
  public_network_access_enabled = true  # GitHub-hosted runners have no VNet access; AAD auth + AcrPush RBAC is the real access gate
  data_endpoint_enabled         = true
  zone_redundancy_enabled       = true
  # Quarantine requires an external scanner (Microsoft Defender for
  # Cloud / Qualys container image scanning) to release images before
  # they become pullable - that integration isn't configured here, so
  # every push would be quarantined forever, blocking cosign signing and
  # AKS pulls alike. Vulnerability gating is already enforced by the
  # Trivy step in ci-cd.yaml, so ACR's own quarantine is redundant.
  quarantine_policy_enabled = false
  tags                      = local.common_tags

  dynamic "georeplications" {
    for_each = toset(var.acr_replica_locations)
    content {
      location                = georeplications.value
      zone_redundancy_enabled = true
      tags                    = local.common_tags
    }
  }
}

# aks cluster
#
# host_encryption_enabled on the node pools is off (see CKV_AZURE_227 skip
# below): this is a Free Trial subscription, which can't request quota
# increases, and is already at its 4 vCPU/region cap across the system+user
# pools. Enabling host encryption needs temporary_name_for_rotation, which
# needs 2 spare vCPUs for a temp node pool during rotation - not available
# here. Revisit once the subscription moves to Pay-As-You-Go.
#checkov:skip=CKV_AZURE_117:Disk Encryption Set (CMK) is environment-specific and requires an externally managed key lifecycle; baseline uses platform-managed encryption plus host encryption.
resource "azurerm_kubernetes_cluster" "main" {
  #checkov:skip=CKV_AZURE_117:Cluster uses host encryption + platform-managed encryption; DES/CMK rollout is externalized.
  #checkov:skip=CKV_AZURE_227:Host encryption needs temporary_name_for_rotation, which requires 2 extra vCPUs during rotation; this Free Trial subscription is capped at 4 vCPUs/region (fully used) and ineligible for quota increases. Revisit after subscription upgrade.
  name                    = "${local.name_prefix}-aks"
  resource_group_name     = azurerm_resource_group.main.name
  location                = azurerm_resource_group.main.location
  dns_prefix              = "${local.name_prefix}-aks"
  kubernetes_version      = var.kubernetes_version
  sku_tier                = "Standard"
  private_cluster_enabled = var.enable_private_cluster
  azure_policy_enabled    = true
  # Direct kubeconfig access never works for this private cluster from
  # outside the VNet - the only path in is `az aks command invoke`, which
  # goes through Azure RBAC on the management plane rather than local
  # accounts. AAD integration has to be on before local_account_disabled
  # can be true, so the azure_active_directory_role_based_access_control
  # block below is unconditional even with an empty admin group list.
  local_account_disabled            = true
  automatic_upgrade_channel         = var.aks_automatic_upgrade_channel
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
    host_encryption_enabled      = false # see CKV_AZURE_227 skip above - Free Trial subscription quota cap
    upgrade_settings {
      max_surge = "33%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  azure_active_directory_role_based_access_control {
    tenant_id              = data.azurerm_client_config.current.tenant_id
    admin_group_object_ids = var.aks_admin_group_object_ids
    azure_rbac_enabled     = true
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
      # node counts drift once the cluster autoscaler is active on the user
      # pool, don't fight it on every plan
      default_node_pool[0].node_count,
    ]
  }
}

#checkov:skip=CKV_AZURE_227:Host encryption needs temporary_name_for_rotation, which requires 2 extra vCPUs during rotation; this Free Trial subscription is capped at 4 vCPUs/region (fully used) and ineligible for quota increases. Revisit after subscription upgrade.
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  #checkov:skip=CKV_AZURE_227:Host encryption needs temporary_name_for_rotation, which requires 2 extra vCPUs during rotation; this Free Trial subscription is capped at 4 vCPUs/region (fully used) and ineligible for quota increases. Revisit after subscription upgrade.
  name                    = "user"
  kubernetes_cluster_id   = azurerm_kubernetes_cluster.main.id
  vm_size                 = var.user_node_vm_size
  vnet_subnet_id          = azurerm_subnet.aks.id
  mode                    = "User"
  max_pods                = 50
  os_disk_type            = "Ephemeral"
  os_disk_size_gb         = 64
  host_encryption_enabled = false # see CKV_AZURE_227 skip above - Free Trial subscription quota cap
  auto_scaling_enabled    = true
  min_count               = var.user_node_min_count
  max_count               = var.user_node_max_count
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

# lets AKS's kubelet identity pull from ACR, no imagePullSecrets needed
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

# Local accounts are disabled and azure_rbac_enabled = true above, so Azure
# AD group membership alone doesn't get a human kubectl/helm/argocd access -
# these two role assignments are what actually get the operator in:
#   - Cluster User Role: lets get-credentials/command invoke fetch a kubeconfig
#   - RBAC Cluster Admin: authorizes Kubernetes object access once authenticated
resource "azurerm_role_assignment" "operator_aks_cluster_user" {
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = var.terraform_operator_object_id
}

resource "azurerm_role_assignment" "operator_aks_rbac_cluster_admin" {
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = var.terraform_operator_object_id
}
