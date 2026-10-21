# AKS cluster hardened for a government-style platform:
#   - Entra ID authentication + Azure RBAC for Kubernetes; local accounts disabled
#   - OIDC issuer + workload identity (pods get Azure tokens, no secrets)
#   - Azure CNI Overlay powered by Cilium, with network policy enforcement
#   - Key Vault Secrets Store CSI driver with rotation
#   - Container Insights + control-plane audit logs to Log Analytics
#   - Automatic patch-version and node-image upgrades

data "azurerm_client_config" "current" {}

resource "azurerm_kubernetes_cluster" "this" {
  #checkov:skip=CKV_AZURE_6:API server must be reachable from GitHub-hosted runners; access requires Entra ID and local accounts are disabled. Restrict via api_server_authorized_ip_ranges or private cluster with self-hosted runners.
  #checkov:skip=CKV_AZURE_115:Private cluster requires self-hosted runners/jump host; deferred (see ADR 0002).
  #checkov:skip=CKV_AZURE_117:Customer-managed disk encryption set is out of scope; platform-managed keys are used.
  #checkov:skip=CKV_AZURE_226:Ephemeral OS disks are not supported on the small B-series nodes used for cost control.
  #checkov:skip=CKV_AZURE_227:Encryption at host requires a subscription feature registration; not assumed.
  #checkov:skip=CKV_AZURE_232:Single node pool (system + workloads) to minimise portfolio cost.
  #checkov:skip=CKV_AZURE_170:sku_tier is per-environment; prod sets Standard (SLA) in live/prod/env.hcl, dev uses Free.
  name                              = "aks-${var.name_prefix}"
  location                          = var.location
  resource_group_name               = var.resource_group_name
  dns_prefix                        = "aks-${var.name_prefix}"
  kubernetes_version                = var.kubernetes_version
  sku_tier                          = var.sku_tier
  automatic_upgrade_channel         = "patch"
  node_os_upgrade_channel           = "NodeImage"
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  local_account_disabled            = true
  role_based_access_control_enabled = true
  azure_policy_enabled              = var.azure_policy_enabled
  tags                              = var.tags

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  default_node_pool {
    name                        = "system"
    vm_size                     = var.node_vm_size
    vnet_subnet_id              = var.subnet_id
    auto_scaling_enabled        = true
    min_count                   = var.node_min_count
    max_count                   = var.node_max_count
    max_pods                    = 50
    os_sku                      = "AzureLinux"
    temporary_name_for_rotation = "systemtmp"
    tags                        = var.tags

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    load_balancer_sku   = "standard"
    pod_cidr            = "192.168.0.0/16"
    service_cidr        = "172.16.0.0/16"
    dns_service_ip      = "172.16.0.10"
  }

  dynamic "api_server_access_profile" {
    for_each = length(var.api_server_authorized_ip_ranges) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.api_server_authorized_ip_ranges
    }
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true
  }

  lifecycle {
    # The autoscaler owns node_count; the upgrade channel owns patch versions.
    ignore_changes = [
      default_node_pool[0].node_count,
      kubernetes_version,
    ]
  }
}

# Kubelet pulls images from ACR with its managed identity (no imagePullSecrets).
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                            = var.acr_id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

# BYO subnet: the cluster identity manages load balancer and NIC bindings in it.
resource "azurerm_role_assignment" "cluster_network_contributor" {
  scope                            = var.subnet_id
  role_definition_name             = "Network Contributor"
  principal_id                     = azurerm_kubernetes_cluster.this.identity[0].principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "cluster_admin" {
  for_each = toset(var.admin_object_ids)

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  name                       = "diag-to-log-analytics"
  target_resource_id         = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  # kube-audit-admin excludes get/list noise while keeping every mutating call.
  dynamic "enabled_log" {
    for_each = toset(["kube-audit-admin", "kube-apiserver", "guard", "cluster-autoscaler"])
    content {
      category = enabled_log.value
    }
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
