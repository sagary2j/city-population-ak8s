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
  default     = "eastus"
}

variable "tags" {
  description = "Common resource tags applied to everything this stack creates."
  type        = map(string)
  default = {
    workload   = "city-population-api"
    managed_by = "terraform"
  }
}

# networking
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
    recommended for production).
  EOT
  type        = list(string)
  default     = []
}

variable "enable_private_cluster" {
  description = "If true, the AKS API server is only reachable from within the VNet (requires a self-hosted runner or VPN/bastion for kubectl/helm/argocd access)."
  type        = bool
  default     = true
}

variable "argocd_ui_allowed_cidrs" {
  description = <<-EOT
    CIDR ranges (e.g. ["203.0.113.4/32"]) allowed to reach the ArgoCD UI's
    public LoadBalancer on port 443. Leave empty (default) to keep ArgoCD
    unreachable from the internet - the NSG allow rule is only created when
    this list is non-empty. Scripts/bootstrap-argocd.sh's --expose-ui flag
    also sets the matching Kubernetes Service loadBalancerSourceRanges, so
    both layers (NSG + Service) must agree for access to actually work.
  EOT
  type        = list(string)
  default     = []
}

# aks
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

# acr
variable "acr_sku" {
  description = "Azure Container Registry SKU (Premium required for security controls used by this stack)."
  type        = string
  default     = "Premium"

  validation {
    condition     = var.acr_sku == "Premium"
    error_message = "acr_sku must be Premium (required for geo-replication, zone redundancy, trust/quarantine, and dedicated endpoints)."
  }
}

# github oidc federation (passwordless CI/CD auth to Azure)
variable "create_github_oidc_identity" {
  description = "If true, create an Azure AD App Registration + federated credentials trusting GitHub Actions OIDC tokens from the given repository, scoped to push images to ACR and deploy to AKS. Set to false if this identity is managed elsewhere."
  type        = bool
  default     = true
}

variable "github_repository" {
  description = "GitHub repository in 'owner/repo' form, used to scope the OIDC federated credential trust (subject claim)."
  type        = string
  default     = "sagary2j/city-population-ak8s"
}

# GitHub now issues immutable `sub` claims (owner/repo IDs embedded, e.g.
# repo:OWNER@OWNER_ID/REPO@REPO_ID:...) for repositories created, renamed, or
# transferred after 2026-07-15. Find these via:
#   curl -s -H "Authorization: Bearer $(gh auth token)" https://api.github.com/repos/<owner>/<repo> | jq '.id, .owner.id'
variable "github_owner_id" {
  description = "Numeric GitHub owner (user/org) ID, required to build the immutable OIDC subject claim format now used by this repository."
  type        = string
  default     = "15179979"
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID, required to build the immutable OIDC subject claim format now used by this repository."
  type        = string
  default     = "1313745460"
}

variable "tfstate_resource_group_name" {
  description = "Resource group holding the Terraform remote state storage account."
  type        = string
  default     = "citypop-dev-tfstate-rg"
}

variable "tfstate_storage_account_name" {
  description = "Storage account holding the Terraform remote state container."
  type        = string
  default     = "citypopdevtfstate5176"
}

variable "github_oidc_environments" {
  description = "GitHub Environments (e.g. dev, prod) allowed to federate. A federated credential is created per environment plus one for the default branch."
  type        = list(string)
  default     = ["dev", "prod"]
}

# My Principle object IDs
variable "terraform_operator_object_id" {
  description = "Azure AD object ID of the human operator retaining Key Vault Secrets Officer access, independent of the CI identity."
  type        = string
  default     = "d0c0196a-a06b-485e-8ea1-3edde579b117"
}

variable "github_default_branch" {
  description = "Default branch allowed to federate for non-environment (e.g. plan-only) workflow runs."
  type        = string
  default     = "main"
}

# key vault (referenced from README)
variable "enable_key_vault" {
  description = "Create an Azure Key Vault for application/Elasticsearch secrets, wired up for the AKS Secrets Store CSI Driver via workload identity."
  type        = bool
  default     = true
}

variable "acr_replica_locations" {
  description = "Additional Azure regions for ACR geo-replication (Premium SKU only). Must be regions that support Availability Zones, since zone_redundancy_enabled = true is set for each replica."
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
