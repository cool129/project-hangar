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

variable "kubernetes_version" {
  description = "AKS version. null = current default GA version; patches are applied automatically."
  type        = string
  default     = null
}

variable "sku_tier" {
  description = "Free (no SLA) or Standard (financially backed uptime SLA)."
  type        = string
  default     = "Free"

  validation {
    condition     = contains(["Free", "Standard"], var.sku_tier)
    error_message = "sku_tier must be Free or Standard."
  }
}

variable "node_vm_size" {
  description = "VM size of the system node pool."
  type        = string
  default     = "Standard_B2ms"
}

variable "node_min_count" {
  description = "Autoscaler lower bound."
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Autoscaler upper bound."
  type        = number
  default     = 3
}

variable "subnet_id" {
  description = "Subnet for AKS nodes."
  type        = string
}

variable "acr_id" {
  description = "Registry the kubelet identity is allowed to pull from."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Workspace for Container Insights and control-plane logs."
  type        = string
}

variable "admin_object_ids" {
  description = "Entra object IDs granted Azure Kubernetes Service RBAC Cluster Admin."
  type        = list(string)
  default     = []
}

variable "api_server_authorized_ip_ranges" {
  description = "CIDRs allowed to reach the API server. Empty = unrestricted (required for GitHub-hosted runners)."
  type        = list(string)
  default     = []
}

variable "azure_policy_enabled" {
  description = "Enable the Azure Policy (Gatekeeper) add-on."
  type        = bool
  default     = true
}
