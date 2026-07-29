# Copy to dev.tfvars (or stage.tfvars / prod.tfvars) and adjust, then:
#   terraform apply -var-file=dev.tfvars

project_name = "citypop"
environment  = "dev"
location     = "eastus"

vnet_address_space        = ["10.20.0.0/16"]
aks_subnet_address_prefix = ["10.20.1.0/24"]

# Lock this down to your CI runner egress ranges / office VPN in real use.
api_server_authorized_ip_ranges = []
enable_private_cluster          = true

# CIDRs allowed to reach the ArgoCD UI's public LoadBalancer (see
# scripts/bootstrap-argocd.sh --expose-ui). Leave empty to keep the subnet's
# NSG fully closed to inbound internet traffic. Must be applied via
# `terraform apply` BEFORE running the script with --expose-ui, since the
# NSG rule and the Service's loadBalancerSourceRanges both have to agree.
argocd_ui_allowed_cidrs = ["109.243.64.162/32"] #my home IP

kubernetes_version = "1.35"
# Subscription is capped at 4 total vCPUs in this region: 1 system node +
# 1 user node of Standard_D2ds_v7 (2 vCPU each) = 4 vCPU total, no headroom.
system_node_count   = 1
system_node_vm_size = "Standard_D2ds_v7"
user_node_min_count = 1
user_node_max_count = 1
user_node_vm_size   = "Standard_D2ds_v7"

# Azure AD group(s) that should get cluster-admin via Azure AD RBAC.
# Find with: az ad group show --group "<name>" --query id -o tsv
aks_admin_group_object_ids = []

acr_sku = "Premium"
# westus does not support Availability Zones, which georeplications requires
# (zone_redundancy_enabled = true); northeurope pairs well with eastus/westeurope.
acr_replica_locations = ["northeurope"]
create_github_oidc_identity = true
github_repository           = "sagary2j/city-population-ak8s"
github_oidc_environments    = ["dev", "prod"]
github_default_branch       = "main"
enable_key_vault            = true
