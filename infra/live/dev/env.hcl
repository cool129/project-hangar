# Dev: smallest viable footprint. Deploy, demo, destroy.
locals {
  environment        = "dev"
  vnet_address_space = "10.10.0.0/16"

  log_retention_days = 30
  log_daily_quota_gb = 1

  acr_sku = "Basic"

  keyvault = {
    purge_protection_enabled   = false # lets `make infra-destroy` fully clean up
    soft_delete_retention_days = 7
  }

  aks = {
    sku_tier       = "Free"
    node_vm_size   = "Standard_B2ms"
    node_min_count = 1
    node_max_count = 3
  }

  postgres = {
    sku_name                  = "B_Standard_B1ms"
    backup_retention_days     = 7
    high_availability_enabled = false
  }

  legacy_vm = {
    vm_size = "Standard_B1ms"
  }
}
