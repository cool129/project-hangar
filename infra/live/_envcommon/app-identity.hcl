# Workload identity for the Sortie Tracker service account. To onboard another
# mission app, copy this file and change workload_name / namespace / service account.
terraform {
  source = "${get_repo_root()}/infra/modules//workload_identity"
}

dependency "foundation" {
  config_path = "${get_terragrunt_dir()}/../foundation"

  mock_outputs = {
    resource_group_name = "rg-mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependency "aks" {
  config_path = "${get_terragrunt_dir()}/../aks"

  mock_outputs = {
    oidc_issuer_url = "https://eastus2.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/mock/"
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
  resource_group_name  = dependency.foundation.outputs.resource_group_name
  oidc_issuer_url      = dependency.aks.outputs.oidc_issuer_url
  key_vault_id         = dependency.keyvault.outputs.id
  workload_name        = "sortie-tracker"
  namespace            = "sortie-tracker"
  service_account_name = "sortie-tracker"
}
