variable "name_prefix" {
  description = "Prefix for resource names, e.g. hangar-dev."
  type        = string
}

variable "location" {
  description = "Azure region (log alerts are regional resources)."
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

variable "action_group_id" {
  description = "Action group notified by every alert."
  type        = string
}

variable "aks_cluster_id" {
  description = "AKS cluster to watch."
  type        = string
}

variable "postgres_server_id" {
  description = "PostgreSQL Flexible Server to watch."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Workspace holding Container Insights logs."
  type        = string
}

variable "app_error_threshold" {
  description = "ERROR-level app log lines per 5 minutes that trigger the log alert."
  type        = number
  default     = 10
}
