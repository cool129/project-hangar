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

variable "postgres_version" {
  description = "Major PostgreSQL version."
  type        = string
  default     = "16"
}

variable "sku_name" {
  description = "Compute SKU, e.g. B_Standard_B1ms (burstable) or GP_Standard_D2ds_v5."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "storage_mb" {
  description = "Allocated storage in MB."
  type        = number
  default     = 32768
}

variable "backup_retention_days" {
  description = "Point-in-time restore window (7-35 days)."
  type        = number
  default     = 7
}

variable "high_availability_enabled" {
  description = "Zone-redundant standby. Not available on Burstable SKUs."
  type        = bool
  default     = false
}

variable "admin_username" {
  description = "Administrator login."
  type        = string
  default     = "hangaradmin"
}

variable "database_name" {
  description = "Application database created on the server."
  type        = string
  default     = "sortie_tracker"
}

variable "delegated_subnet_id" {
  description = "Subnet delegated to Microsoft.DBforPostgreSQL/flexibleServers."
  type        = string
}

variable "private_dns_zone_id" {
  description = "Private DNS zone (*.postgres.database.azure.com) linked to the VNet."
  type        = string
}

variable "key_vault_id" {
  description = "Vault that stores the generated connection secrets."
  type        = string
}

variable "secret_rotation_days" {
  description = "Secret expiry horizon; the expiry date rolls forward on apply after this many days."
  type        = number
  default     = 180
}

variable "log_analytics_workspace_id" {
  description = "Workspace that receives server logs."
  type        = string
}
