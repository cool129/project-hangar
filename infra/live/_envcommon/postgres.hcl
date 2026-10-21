# Managed PostgreSQL (migration target); credentials written to Key Vault.
locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${get_repo_root()}/infra/modules//postgres"
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

dependency "network" {
  config_path = "${get_terragrunt_dir()}/../network"

  mock_outputs = {
    subnet_ids = {
      db = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-db"
    }
    postgres_private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/privateDnsZones/mock.private.postgres.database.azure.com"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependency "keyvault" {
  config_path = "${get_terragrunt_dir()}/../keyvault"

  mock_outputs = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.KeyVault/vaults/kv-mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  resource_group_name        = dependency.foundation.outputs.resource_group_name
  log_analytics_workspace_id = dependency.foundation.outputs.log_analytics_workspace_id
  delegated_subnet_id        = dependency.network.outputs.subnet_ids["db"]
  private_dns_zone_id        = dependency.network.outputs.postgres_private_dns_zone_id
  key_vault_id               = dependency.keyvault.outputs.id
  sku_name                   = local.env.postgres.sku_name
  backup_retention_days      = local.env.postgres.backup_retention_days
  high_availability_enabled  = local.env.postgres.high_availability_enabled
}
