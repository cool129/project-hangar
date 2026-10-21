output "id" {
  value      = azurerm_key_vault.this.id
  depends_on = [time_sleep.rbac_propagation]
}

output "name" {
  value = azurerm_key_vault.this.name
}

output "uri" {
  value = azurerm_key_vault.this.vault_uri
}

output "tenant_id" {
  value = azurerm_key_vault.this.tenant_id
}
