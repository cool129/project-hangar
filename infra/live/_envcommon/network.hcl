# VNet, segmented subnets + NSGs, PostgreSQL private DNS zone.
locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${get_repo_root()}/infra/modules//network"
}

# Mock outputs let `plan` run across a fresh environment before upstream units exist.
dependency "foundation" {
  config_path = "${get_terragrunt_dir()}/../foundation"

  mock_outputs = {
    resource_group_name = "rg-mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  resource_group_name = dependency.foundation.outputs.resource_group_name
  address_space       = local.env.vnet_address_space
  allowed_ssh_cidrs   = compact(split(",", get_env("HANGAR_ALLOWED_SSH_CIDRS", "")))
}
