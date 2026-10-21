# Azure Monitor alerts for the PaaS layer and a log-based safety net.
terraform {
  source = "${get_repo_root()}/infra/modules//alerts"
}

dependency "foundation" {
  config_path = "${get_terragrunt_dir()}/../foundation"

  mock_outputs = {
    resource_group_name        = "rg-mock"
    action_group_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Insights/actionGroups/ag-mock"
    log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.OperationalInsights/workspaces/log-mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependency "aks" {
  config_path = "${get_terragrunt_dir()}/../aks"

  mock_outputs = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.ContainerService/managedClusters/aks-mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependency "postgres" {
  config_path = "${get_terragrunt_dir()}/../postgres"

  mock_outputs = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  resource_group_name        = dependency.foundation.outputs.resource_group_name
  action_group_id            = dependency.foundation.outputs.action_group_id
  log_analytics_workspace_id = dependency.foundation.outputs.log_analytics_workspace_id
  aks_cluster_id             = dependency.aks.outputs.id
  postgres_server_id         = dependency.postgres.outputs.id
}
