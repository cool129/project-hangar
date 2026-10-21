# AKS cluster with workload identity, Cilium network policy and Key Vault CSI.
locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${get_repo_root()}/infra/modules//aks"
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
      aks = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-aks"
    }
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependency "acr" {
  config_path = "${get_terragrunt_dir()}/../acr"

  mock_outputs = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.ContainerRegistry/registries/acrmock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  resource_group_name             = dependency.foundation.outputs.resource_group_name
  log_analytics_workspace_id      = dependency.foundation.outputs.log_analytics_workspace_id
  subnet_id                       = dependency.network.outputs.subnet_ids["aks"]
  acr_id                          = dependency.acr.outputs.id
  sku_tier                        = local.env.aks.sku_tier
  node_vm_size                    = local.env.aks.node_vm_size
  node_min_count                  = local.env.aks.node_min_count
  node_max_count                  = local.env.aks.node_max_count
  api_server_authorized_ip_ranges = compact(split(",", get_env("HANGAR_API_AUTHORIZED_CIDRS", "")))
}
