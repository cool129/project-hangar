# The "legacy" host: a plain Ubuntu VM that Ansible turns into the pre-migration
# Sortie Tracker deployment (systemd service + local PostgreSQL). It is
# deliberately bare here; all configuration lives in ansible/ so the
# hand-built-server problem is reproduced and then automated away.
#
# Tags drive the Ansible azure_rm dynamic inventory (keyed_groups on `role`).

resource "azurerm_public_ip" "this" {
  count = var.public_ip_enabled ? 1 : 0

  name                = "pip-${var.name_prefix}-legacy"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "this" {
  #checkov:skip=CKV_AZURE_119:Public IP lets the operator run Ansible during the migration; SSH restricted by NSG to allowed_ssh_cidrs. Disable with public_ip_enabled=false.
  name                = "nic-${var.name_prefix}-legacy"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = var.public_ip_enabled ? azurerm_public_ip.this[0].id : null
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  #checkov:skip=CKV_AZURE_178:False positive; SSH keys are used and password authentication is disabled.
  name                            = "vm-${var.name_prefix}-legacy"
  computer_name                   = "sortie-legacy"
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  allow_extension_operations      = false
  network_interface_ids           = [azurerm_network_interface.this.id]
  tags                            = merge(var.tags, { role = "legacy-app", app = "sortie-tracker" })

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    name                 = "osdisk-${var.name_prefix}-legacy"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  boot_diagnostics {}
}
