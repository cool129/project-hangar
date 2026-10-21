output "client_id" {
  description = "Goes in the service account annotation azure.workload.identity/client-id."
  value       = azurerm_user_assigned_identity.this.client_id
}

output "principal_id" {
  value = azurerm_user_assigned_identity.this.principal_id
}

output "id" {
  value = azurerm_user_assigned_identity.this.id
}

output "tenant_id" {
  value = azurerm_user_assigned_identity.this.tenant_id
}
