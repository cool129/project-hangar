# Legacy Ubuntu VM: the migration source, configured by Ansible (Phase 5).
locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals

  # CI passes the key itself; locally it defaults to your ed25519 public key file.
  # Empty values (blank lines in .env.hangar) fall through to the default.
  ssh_key_env  = get_env("HANGAR_SSH_PUBLIC_KEY", "")
  ssh_key_file = coalesce(get_env("HANGAR_SSH_PUBLIC_KEY_FILE", ""), "~/.ssh/id_ed25519.pub")
}

terraform {
  source = "${get_repo_root()}/infra/modules//legacy_vm"
}

dependency "foundation" {
  config_path = "${get_terragrunt_dir()}/../foundation"

  mock_outputs = {
    resource_group_name = "rg-mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependency "network" {
  config_path = "${get_terragrunt_dir()}/../network"

  mock_outputs = {
    subnet_ids = {
      legacy = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-legacy"
    }
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  resource_group_name = dependency.foundation.outputs.resource_group_name
  subnet_id           = dependency.network.outputs.subnet_ids["legacy"]
  vm_size             = local.env.legacy_vm.vm_size
  ssh_public_key      = local.ssh_key_env != "" ? local.ssh_key_env : try(trimspace(file(pathexpand(local.ssh_key_file))), "")
}
