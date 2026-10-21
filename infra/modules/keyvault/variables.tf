variable "name_prefix" {
  description = "Prefix for resource names, e.g. hangar-dev."
  type        = string
}

variable "unique_suffix" {
  description = "Short stable suffix that makes globally-unique names unique."
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

variable "admin_object_ids" {
  description = "Entra object IDs (operator, CI identity) granted Key Vault Secrets Officer."
  type        = list(string)
  default     = []
}

variable "purge_protection_enabled" {
  description = "Prevents permanent deletion during the retention window. Disable only for throwaway dev environments."
  type        = bool
  default     = true
}

variable "soft_delete_retention_days" {
  description = "Days a deleted vault/secret is recoverable (7-90)."
  type        = number
  default     = 90
}

variable "log_analytics_workspace_id" {
  description = "Workspace that receives vault audit logs."
  type        = string
}
