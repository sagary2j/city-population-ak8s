# Copy to dev.tfvars (or stage.tfvars / prod.tfvars) and adjust, then:
#   terraform apply -var-file=dev.tfvars

project_name = "citypop"
environment  = "dev"
location     = "westeurope"

vnet_address_space        = ["10.20.0.0/16"]
aks_subnet_address_prefix = ["10.20.1.0/24"]

# Lock this down to your CI runner egress ranges / office VPN in real use.
api_server_authorized_ip_ranges = []
enable_private_cluster          = true

kubernetes_version  = "1.30"
system_node_count   = 2
system_node_vm_size = "Standard_D2s_v5"
user_node_min_count = 2
user_node_max_count = 6
user_node_vm_size   = "Standard_D4s_v5"

# Azure AD group(s) that should get cluster-admin via Azure AD RBAC.
# Find with: az ad group show --group "<name>" --query id -o tsv
aks_admin_group_object_ids = []

acr_sku               = "Premium"
acr_replica_locations = ["northeurope"]

create_github_oidc_identity = true
github_repository           = "sagary2j/city-population-ak8s"
github_oidc_environments    = ["dev", "prod"]
github_default_branch       = "main"

enable_key_vault = true
