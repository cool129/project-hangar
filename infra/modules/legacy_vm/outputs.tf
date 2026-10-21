output "id" {
  value = azurerm_linux_virtual_machine.this.id
}

output "name" {
  value = azurerm_linux_virtual_machine.this.name
}

output "private_ip" {
  value = azurerm_network_interface.this.private_ip_address
}

output "public_ip" {
  value = var.public_ip_enabled ? azurerm_public_ip.this[0].ip_address : null
}

output "admin_username" {
  value = var.admin_username
}

output "principal_id" {
  value = azurerm_linux_virtual_machine.this.identity[0].principal_id
}
