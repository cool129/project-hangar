output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "vnet_name" {
  value = azurerm_virtual_network.this.name
}

output "subnet_ids" {
  description = "Subnet IDs keyed by role: aks, db, legacy."
  value       = { for k, s in azurerm_subnet.this : k => s.id }
}

output "subnet_cidrs" {
  value = { for k, s in local.subnets : k => s.cidr }
}

output "postgres_private_dns_zone_id" {
  # Depend on the VNet link so PostgreSQL is never created before DNS resolves.
  value      = azurerm_private_dns_zone.postgres.id
  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]
}
