# Prod: SLA-backed control plane, zone-redundant database, longer retention.
# Expensive relative to dev; stand it up for demos and tear it down after.
locals {
  environment        = "prod"
  vnet_address_space = "10.20.0.0/16"

  log_retention_days = 90
  log_daily_quota_gb = -1

  acr_sku = "Standard"

  keyvault = {
    purge_protection_enabled   = true
    soft_delete_retention_days = 90
  }

  aks = {
    sku_tier       = "Standard"
    node_vm_size   = "Standard_D2s_v5"
    node_min_count = 2
    node_max_count = 5
  }

  postgres = {
    sku_name                  = "GP_Standard_D2ds_v5"
    backup_retention_days     = 35
    high_availability_enabled = true
  }

  legacy_vm = {
    vm_size = "Standard_B1ms"
  }
}
