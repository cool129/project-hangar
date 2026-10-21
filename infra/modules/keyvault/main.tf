# Key Vault in RBAC mode (no legacy access policies). Workloads read secrets
# through the AKS Secrets Store CSI driver using workload identity; nothing is
# baked into images, Helm values, or pipeline variables.

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "this" {
  #checkov:skip=CKV_AZURE_109:GitHub-hosted runners write secrets during apply; data plane is Entra ID + RBAC only. Private endpoint needs self-hosted runners.
  #checkov:skip=CKV_AZURE_189:Same as CKV_AZURE_109: public endpoint kept for hosted CI runners, guarded by RBAC.
  #checkov:skip=CKV2_AZURE_32:Private endpoint deferred until self-hosted runners exist (see ADR 0002).
  name                          = "kv-${var.name_prefix}-${var.unique_suffix}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = var.purge_protection_enabled
  soft_delete_retention_days    = var.soft_delete_retention_days
  public_network_access_enabled = true
  tags                          = var.tags

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }
}

resource "azurerm_role_assignment" "secrets_officer" {
  for_each = toset(var.admin_object_ids)

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}

# RBAC grants take up to a minute to reach the Key Vault data plane. Units that
# write secrets consume `id` below, which waits for this on first creation.
resource "time_sleep" "rbac_propagation" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.secrets_officer]
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  name                       = "diag-to-log-analytics"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category_group = "audit"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
