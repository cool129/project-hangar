variable "name_prefix" {
  description = "Prefix for resource names, e.g. hangar-dev."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "log_retention_days" {
  description = "Log Analytics retention in days."
  type        = number
  default     = 30
}

variable "log_daily_quota_gb" {
  description = "Daily ingestion cap in GB (-1 = unlimited). Guards against runaway cost in non-prod."
  type        = number
  default     = -1
}

variable "alert_email_addresses" {
  description = "Email addresses notified by the platform action group."
  type        = list(string)
  default     = []
}
