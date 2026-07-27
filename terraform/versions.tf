terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.53"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state in Azure Storage. The storage account/container must exist
  # before `terraform init` runs -- see scripts/bootstrap-tfstate.sh, which
  # creates them idempotently. Values are intentionally supplied via
  # `-backend-config` (CLI flag or partial config file) rather than hardcoded
  # here, since the backend cannot reference variables and differs per
  # environment (dev/stage/prod each get their own state file/key).
  #
  # terraform init \
  #   -backend-config="resource_group_name=<tfstate-rg>" \
  #   -backend-config="storage_account_name=<tfstate-sa>" \
  #   -backend-config="container_name=tfstate" \
  #   -backend-config="key=city-population/<environment>.tfstate"
  backend "azurerm" {}
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

provider "azuread" {}
