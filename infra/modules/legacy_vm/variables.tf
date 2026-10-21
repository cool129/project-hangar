variable "name_prefix" {
  description = "Prefix for resource names, e.g. hangar-dev."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy into."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "subnet_id" {
  description = "Legacy subnet."
  type        = string
}

variable "vm_size" {
  description = "VM size. Must fit the app plus a local PostgreSQL."
  type        = string
  default     = "Standard_B1ms"
}

variable "admin_username" {
  description = "SSH user Ansible connects as."
  type        = string
  default     = "hangaradmin"
}

variable "ssh_public_key" {
  description = "OpenSSH public key for admin_username. Password authentication is disabled."
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) ", var.ssh_public_key))
    error_message = "ssh_public_key must be an OpenSSH public key (set HANGAR_SSH_PUBLIC_KEY)."
  }
}

variable "public_ip_enabled" {
  description = "Attach a public IP so Ansible can reach the VM from the operator machine (NSG limits SSH to allowed_ssh_cidrs)."
  type        = bool
  default     = true
}
