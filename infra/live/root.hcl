# Root Terragrunt configuration, included by every unit.
#
# Responsibilities:
#   - One remote state file per unit, keyed by its path (dev/aks/terraform.tfstate)
#   - Generated provider + backend blocks so modules stay provider-agnostic
#   - Naming, tagging and identity inputs shared by every unit
#
# Required environment (written to .env.hangar by `make bootstrap`, exported by make;
# set as GitHub repository variables for CI):
#   AZURE_SUBSCRIPTION_ID, TF_STATE_RG, TF_STATE_SA
# Optional: AZURE_LOCATION, TF_STATE_CONTAINER, HANGAR_OPERATOR_OBJECT_ID, HANGAR_CI_OBJECT_ID

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env      = local.env_vars.locals.environment

  project         = "hangar"
  location        = get_env("AZURE_LOCATION", "eastus2")
  subscription_id = get_env("AZURE_SUBSCRIPTION_ID")

  # Globally-unique names (ACR, Key Vault, PostgreSQL) need a suffix; derive a
  # stable one from the subscription so every run computes the same names.
  unique_suffix = substr(sha256(local.subscription_id), 0, 6)

  # Explicit admin list (instead of "whoever runs apply") so local and CI runs
  # produce identical role assignments and never fight each other.
  admin_object_ids = compact([
    get_env("HANGAR_OPERATOR_OBJECT_ID", ""),
    get_env("HANGAR_CI_OBJECT_ID", ""),
  ])
}

remote_state {
  backend = "azurerm"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    resource_group_name  = get_env("TF_STATE_RG")
    storage_account_name = get_env("TF_STATE_SA")
    container_name       = get_env("TF_STATE_CONTAINER", "tfstate")
    key                  = "${path_relative_to_include()}/terraform.tfstate"
    # Shared-key auth is disabled on the state account; Entra ID only.
    use_azuread_auth = true
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "azurerm" {
      subscription_id     = "${local.subscription_id}"
      storage_use_azuread = true

      features {
        key_vault {
          purge_soft_delete_on_destroy    = ${local.env == "prod" ? "false" : "true"}
          recover_soft_deleted_key_vaults = true
        }
        resource_group {
          prevent_deletion_if_contains_resources = true
        }
      }
    }
  EOF
}

inputs = {
  environment      = local.env
  location         = local.location
  name_prefix      = "${local.project}-${local.env}"
  unique_suffix    = local.unique_suffix
  admin_object_ids = local.admin_object_ids

  tags = {
    project     = local.project
    environment = local.env
    managed-by  = "terragrunt"
    repo        = "project-hangar"
    cost-center = "portfolio"
  }
}
