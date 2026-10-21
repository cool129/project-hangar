output "id" {
  value = azurerm_postgresql_flexible_server.this.id
}

output "name" {
  value = azurerm_postgresql_flexible_server.this.name
}

output "fqdn" {
  value = azurerm_postgresql_flexible_server.this.fqdn
}

output "database_name" {
  value = azurerm_postgresql_flexible_server_database.app.name
}

output "admin_username" {
  value = var.admin_username
}

output "key_vault_secret_names" {
  description = "Secrets the app's SecretProviderClass mounts."
  value       = sort(keys(azurerm_key_vault_secret.this))
}
