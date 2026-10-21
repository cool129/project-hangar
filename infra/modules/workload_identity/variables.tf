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

variable "workload_name" {
  description = "Short workload name used in the identity name."
  type        = string
}

variable "oidc_issuer_url" {
  description = "AKS OIDC issuer URL."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace of the workload's service account."
  type        = string
}

variable "service_account_name" {
  description = "Kubernetes service account the pods run as."
  type        = string
}

variable "key_vault_id" {
  description = "Vault the workload may read secrets from (Key Vault Secrets User)."
  type        = string
}
