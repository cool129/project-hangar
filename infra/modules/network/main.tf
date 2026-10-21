# Hub-style VNet for one environment, segmented by workload:
#   snet-aks     AKS nodes (Azure CNI Overlay: pods do not consume VNet IPs)
#   snet-db      delegated to PostgreSQL Flexible Server (private access only)
#   snet-legacy  the legacy VM being migrated off
# Each subnet gets its own NSG; db and legacy deny everything not explicitly allowed.

locals {
  subnets = {
    aks = {
      cidr               = cidrsubnet(var.address_space, 6, 0) # x.x.0.0/22
      deny_other_inbound = false                               # AKS needs LB probes + node-to-node traffic
      rules = [
        { name = "AllowHttpHttpsInbound", priority = 100, ports = ["80", "443"], sources = ["Internet"] },
      ]
    }
    db = {
      cidr               = cidrsubnet(var.address_space, 8, 8) # x.x.8.0/24
      deny_other_inbound = true
      rules = [
        { name = "AllowPostgresFromVnet", priority = 100, ports = ["5432"], sources = ["VirtualNetwork"] },
      ]
    }
    legacy = {
      cidr               = cidrsubnet(var.address_space, 8, 9) # x.x.9.0/24
      deny_other_inbound = true
      rules = concat(
        length(var.allowed_ssh_cidrs) > 0 ? [
          { name = "AllowSshFromOperators", priority = 100, ports = ["22"], sources = var.allowed_ssh_cidrs },
        ] : [],
        [
          { name = "AllowSshFromVnet", priority = 110, ports = ["22"], sources = ["VirtualNetwork"] },
          { name = "AllowAppFromVnet", priority = 120, ports = ["8000"], sources = ["VirtualNetwork"] },
        ],
      )
    }
  }
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "this" {
  for_each = local.subnets

  name                 = "snet-${each.key}"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [each.value.cidr]

  dynamic "delegation" {
    for_each = each.key == "db" ? [1] : []
    content {
      name = "postgres-flexible"
      service_delegation {
        name    = "Microsoft.DBforPostgreSQL/flexibleServers"
        actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      }
    }
  }
}

resource "azurerm_network_security_group" "this" {
  for_each = local.subnets

  name                = "nsg-${var.name_prefix}-${each.key}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  dynamic "security_rule" {
    for_each = each.value.rules
    content {
      name                       = security_rule.value.name
      priority                   = security_rule.value.priority
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_ranges    = security_rule.value.ports
      destination_address_prefix = "*"
      # Service tags must use the singular field; CIDR lists the plural one.
      source_address_prefix   = length(security_rule.value.sources) == 1 ? security_rule.value.sources[0] : null
      source_address_prefixes = length(security_rule.value.sources) > 1 ? security_rule.value.sources : null
    }
  }

  dynamic "security_rule" {
    for_each = each.value.deny_other_inbound ? [1] : []
    content {
      name                       = "DenyAllOtherInbound"
      priority                   = 4000
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "*"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "this" {
  for_each = local.subnets

  subnet_id                 = azurerm_subnet.this[each.key].id
  network_security_group_id = azurerm_network_security_group.this[each.key].id
}

# VNet-integrated Flexible Server requires a private DNS zone ending in
# .postgres.database.azure.com, linked to the VNet that resolves it.
resource "azurerm_private_dns_zone" "postgres" {
  name                = "${var.name_prefix}.private.postgres.database.azure.com"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "link-${var.name_prefix}-postgres"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = var.tags
}
