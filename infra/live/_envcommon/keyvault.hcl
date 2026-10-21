# Key Vault (RBAC mode) holding application secrets.
locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${get_repo_root()}/infra/modules//keyvault"
}

dependency "foundation" {
  config_path = "${get_terragrunt_dir()}/../foundation"

  mock_outputs = {
    resource_group_name        = "rg-mock"
    log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.OperationalInsights/workspaces/log-mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  resource_group_name        = dependency.foundation.outputs.resource_group_name
  log_analytics_workspace_id = dependency.foundation.outputs.log_analytics_workspace_id
  purge_protection_enabled   = local.env.keyvault.purge_protection_enabled
  soft_delete_retention_days = local.env.keyvault.soft_delete_retention_days
}
