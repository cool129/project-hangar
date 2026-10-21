# Azure Database for PostgreSQL Flexible Server: the migration target for the
# legacy VM's local database. Private VNet access only (no public endpoint),
# TLS enforced, connection auditing on, credentials generated here and stored
# straight into Key Vault. Humans never see or type the password.

resource "random_password" "admin" {
  length           = 32
  special          = true
  override_special = "!#%*-_=+"
}

resource "azurerm_postgresql_flexible_server" "this" {
  #checkov:skip=CKV_AZURE_136:Geo-redundant backups double storage cost; single-region portfolio deployment.
  #checkov:skip=CKV2_AZURE_57:Uses VNet integration (delegated subnet + private DNS, public access disabled), which is private by construction; a private endpoint is the alternative model.
  name                          = "psql-${var.name_prefix}-${var.unique_suffix}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  version                       = var.postgres_version
  sku_name                      = var.sku_name
  storage_mb                    = var.storage_mb
  backup_retention_days         = var.backup_retention_days
  geo_redundant_backup_enabled  = false
  delegated_subnet_id           = var.delegated_subnet_id
  private_dns_zone_id           = var.private_dns_zone_id
  public_network_access_enabled = false
  administrator_login           = var.admin_username
  administrator_password        = random_password.admin.result
  tags                          = var.tags

  dynamic "high_availability" {
    for_each = var.high_availability_enabled ? [1] : []
    content {
      mode = "ZoneRedundant"
    }
  }

  lifecycle {
    # Azure picks the zone at creation and may move it during failover.
    ignore_changes = [
      zone,
      high_availability[0].standby_availability_zone,
    ]
  }
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Server parameters for auditing and connection hygiene.
resource "azurerm_postgresql_flexible_server_configuration" "this" {
  for_each = {
    "require_secure_transport"   = "on"
    "log_connections"            = "on"
    "log_disconnections"         = "on"
    "log_checkpoints"            = "on"
    "connection_throttle.enable" = "on"
  }

  name      = each.key
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = each.value
}

# --- Secrets -----------------------------------------------------------------
# Expiry rolls forward every `secret_rotation_days`, giving a compliance-visible
# rotation deadline without a perpetual diff.
resource "time_rotating" "secret_expiry" {
  rotation_days = var.secret_rotation_days
}

locals {
  secret_values = {
    "postgres-host"           = azurerm_postgresql_flexible_server.this.fqdn
    "postgres-database"       = azurerm_postgresql_flexible_server_database.app.name
    "postgres-admin-username" = var.admin_username
    "postgres-admin-password" = random_password.admin.result
  }
}

resource "azurerm_key_vault_secret" "this" {
  # Keys are static so for_each stays known even though one value is sensitive.
  for_each = toset(["postgres-host", "postgres-database", "postgres-admin-username", "postgres-admin-password"])

  name            = each.key
  value           = local.secret_values[each.key]
  key_vault_id    = var.key_vault_id
  content_type    = each.key == "postgres-admin-password" ? "password" : "text/plain"
  expiration_date = time_rotating.secret_expiry.rotation_rfc3339
  tags            = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  name                       = "diag-to-log-analytics"
  target_resource_id         = azurerm_postgresql_flexible_server.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "PostgreSQLLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
