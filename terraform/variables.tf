variable "project_name" {
  description = "Short project identifier used as a naming prefix for all resources."
  type        = string
  default     = "citypop"
}

variable "environment" {
  description = "Deployment environment name (dev, stage, prod). Used in naming and tags."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be one of: dev, stage, prod."
  }
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "westeurope"
}

variable "tags" {
  description = "Common resource tags applied to everything this stack creates."
  type        = map(string)
  default = {
    workload    = "city-population-api"
    managed_by  = "terraform"
    cost_center = "sre-take-home"
  }
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
variable "vnet_address_space" {
  description = "Address space for the AKS virtual network."
  type        = list(string)
  default     = ["10.20.0.0/16"]
}

variable "aks_subnet_address_prefix" {
  description = "Subnet CIDR for AKS nodes/pods (Azure CNI)."
  type        = list(string)
  default     = ["10.20.1.0/24"]
}

variable "api_server_authorized_ip_ranges" {
  description = <<-EOT
    CIDR ranges allowed to reach the AKS API server (e.g. your CI runner's
    egress IPs and office/VPN ranges). Leave empty to allow all (not
    recommended for production -- see README Part D / security hardening).
  EOT
  type        = list(string)
  default     = []
}

variable "enable_private_cluster" {
  description = "If true, the AKS API server is only reachable from within the VNet (requires a self-hosted runner or VPN/bastion for kubectl/helm/argocd access)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# AKS
# ---------------------------------------------------------------------------
variable "kubernetes_version" {
  description = "Kubernetes version for the AKS control plane and default node pool."
  type        = string
  default     = "1.30"
}

variable "system_node_count" {
  description = "Fixed node count for the system node pool."
  type        = number
  default     = 2
}

variable "system_node_vm_size" {
  description = "VM size for the system node pool."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "user_node_min_count" {
  description = "Minimum node count for the autoscaling user (workload) node pool."
  type        = number
  default     = 2
}

variable "user_node_max_count" {
  description = "Maximum node count for the autoscaling user (workload) node pool."
  type        = number
  default     = 6
}

variable "user_node_vm_size" {
  description = "VM size for the user (workload) node pool."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "aks_admin_group_object_ids" {
  description = "Azure AD group object IDs granted cluster-admin via Azure AD RBAC. Leave empty to skip AAD group binding (falls back to `az aks get-credentials --admin` + local accounts, which is disabled by default in this config for production posture)."
  type        = list(string)
  default     = []
}

variable "log_analytics_retention_days" {
  description = "Retention period for the Log Analytics workspace backing Container Insights."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# ACR
# ---------------------------------------------------------------------------
variable "acr_sku" {
  description = "Azure Container Registry SKU (Premium required for security controls used by this stack)."
  type        = string
  default     = "Premium"

  validation {
    condition     = var.acr_sku == "Premium"
    error_message = "acr_sku must be Premium (required for geo-replication, zone redundancy, trust/quarantine, and dedicated endpoints)."
  }
}

# ---------------------------------------------------------------------------
# GitHub OIDC federation (passwordless CI/CD auth to Azure)
# ---------------------------------------------------------------------------
variable "create_github_oidc_identity" {
  description = "If true, create an Azure AD App Registration + federated credentials trusting GitHub Actions OIDC tokens from the given repository, scoped to push images to ACR and deploy to AKS. Set to false if this identity is managed elsewhere."
  type        = bool
  default     = true
}

variable "github_repository" {
  description = "GitHub repository in 'owner/repo' form, used to scope the OIDC federated credential trust (subject claim)."
  type        = string
  default     = "your-org/city-population"
}

variable "github_oidc_environments" {
  description = "GitHub Environments (e.g. dev, prod) allowed to federate. A federated credential is created per environment plus one for the default branch."
  type        = list(string)
  default     = ["dev", "prod"]
}

variable "github_default_branch" {
  description = "Default branch allowed to federate for non-environment (e.g. plan-only) workflow runs."
  type        = string
  default     = "main"
}

# ---------------------------------------------------------------------------
# Key Vault (production secret backing, referenced from README Part D)
# ---------------------------------------------------------------------------
variable "enable_key_vault" {
  description = "Create an Azure Key Vault for application/Elasticsearch secrets, wired up for the AKS Secrets Store CSI Driver via workload identity."
  type        = bool
  default     = true
}

variable "acr_replica_locations" {
  description = "Additional Azure regions for ACR geo-replication (Premium SKU only)."
  type        = list(string)
  default     = ["northeurope"]
}

variable "aks_automatic_upgrade_channel" {
  description = "AKS automatic upgrade channel."
  type        = string
  default     = "stable"

  validation {
    condition     = contains(["patch", "rapid", "node-image", "stable"], var.aks_automatic_upgrade_channel)
    error_message = "aks_automatic_upgrade_channel must be one of: patch, rapid, node-image, stable."
  }
}
