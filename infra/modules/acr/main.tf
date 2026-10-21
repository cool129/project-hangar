# Private container registry. Pulls are authorized by the AKS kubelet identity
# (AcrPull, assigned in the aks module); pushes by the CI identity via Entra ID.
# The admin user is disabled: no shared registry passwords exist.

resource "azurerm_container_registry" "this" {
  #checkov:skip=CKV_AZURE_139:GitHub-hosted runners have dynamic IPs; access is Entra ID-only. Private endpoint needs Premium + self-hosted runners.
  #checkov:skip=CKV_AZURE_163:Images are scanned with Trivy in CI instead of paid Defender for Containers.
  #checkov:skip=CKV_AZURE_164:Image signing/trust policy requires Premium SKU; out of scope for the portfolio budget.
  #checkov:skip=CKV_AZURE_165:Geo-replication requires Premium SKU; single-region portfolio deployment.
  #checkov:skip=CKV_AZURE_166:Quarantine requires Premium SKU; Trivy gate in CI blocks vulnerable images before push.
  #checkov:skip=CKV_AZURE_167:Untagged-manifest retention requires Premium SKU.
  #checkov:skip=CKV_AZURE_233:Zone redundancy requires Premium SKU.
  #checkov:skip=CKV_AZURE_237:Dedicated data endpoints require Premium SKU.
  name                          = "acr${replace(var.name_prefix, "-", "")}${var.unique_suffix}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  sku                           = var.sku
  admin_enabled                 = false
  anonymous_pull_enabled        = false
  public_network_access_enabled = true
  tags                          = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  name                       = "diag-to-log-analytics"
  target_resource_id         = azurerm_container_registry.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "ContainerRegistryRepositoryEvents"
  }

  enabled_log {
    category = "ContainerRegistryLoginEvents"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
