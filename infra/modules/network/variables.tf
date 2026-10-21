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

variable "address_space" {
  description = "VNet CIDR. Must be a /16; subnets are carved from it."
  type        = string

  validation {
    condition     = can(cidrhost(var.address_space, 0)) && endswith(var.address_space, "/16")
    error_message = "address_space must be a valid /16 CIDR, e.g. 10.10.0.0/16."
  }
}

variable "allowed_ssh_cidrs" {
  description = "Operator CIDRs allowed to SSH to the legacy subnet. Empty = no SSH from outside the VNet."
  type        = list(string)
  default     = []
}
