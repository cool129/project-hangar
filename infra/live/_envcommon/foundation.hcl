# Resource group, Log Analytics workspace, alert action group.
locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${get_repo_root()}/infra/modules//foundation"
}

inputs = {
  log_retention_days    = local.env.log_retention_days
  log_daily_quota_gb    = local.env.log_daily_quota_gb
  alert_email_addresses = compact(split(",", get_env("HANGAR_ALERT_EMAILS", "")))
}
