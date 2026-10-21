# Azure Monitor alerts for what in-cluster Prometheus cannot see: the managed
# PostgreSQL service, node-level pressure, and a log-based safety net that
# still fires if the in-cluster monitoring stack itself is down.
# Application SLO alerts live with the app (Helm chart PrometheusRule).

locals {
  metric_alerts = {
    postgres-cpu = {
      scope       = var.postgres_server_id
      namespace   = "Microsoft.DBforPostgreSQL/flexibleServers"
      metric      = "cpu_percent"
      aggregation = "Average"
      operator    = "GreaterThan"
      threshold   = 80
      severity    = 2
      description = "PostgreSQL CPU above 80% for 15 minutes. Check slow queries (runbook: high-latency)."
    }
    postgres-storage = {
      scope       = var.postgres_server_id
      namespace   = "Microsoft.DBforPostgreSQL/flexibleServers"
      metric      = "storage_percent"
      aggregation = "Average"
      operator    = "GreaterThan"
      threshold   = 80
      severity    = 1
      description = "PostgreSQL storage above 80%. Grow storage before the server goes read-only."
    }
    postgres-connections-failed = {
      scope       = var.postgres_server_id
      namespace   = "Microsoft.DBforPostgreSQL/flexibleServers"
      metric      = "connections_failed"
      aggregation = "Total"
      operator    = "GreaterThan"
      threshold   = 5
      severity    = 1
      description = "Failed PostgreSQL connections (credentials, firewall/NSG, or exhaustion). Runbook: db-connectivity."
    }
    aks-node-cpu = {
      scope       = var.aks_cluster_id
      namespace   = "Microsoft.ContainerService/managedClusters"
      metric      = "node_cpu_usage_percentage"
      aggregation = "Average"
      operator    = "GreaterThan"
      threshold   = 85
      severity    = 2
      description = "AKS node CPU above 85%. Autoscaler may be at max_count."
    }
    aks-node-memory = {
      scope       = var.aks_cluster_id
      namespace   = "Microsoft.ContainerService/managedClusters"
      metric      = "node_memory_working_set_percentage"
      aggregation = "Average"
      operator    = "GreaterThan"
      threshold   = 85
      severity    = 2
      description = "AKS node memory above 85%. Expect evictions and OOM kills."
    }
  }
}

resource "azurerm_monitor_metric_alert" "this" {
  for_each = local.metric_alerts

  name                = "alert-${var.name_prefix}-${each.key}"
  resource_group_name = var.resource_group_name
  scopes              = [each.value.scope]
  description         = each.value.description
  severity            = each.value.severity
  frequency           = "PT5M"
  window_size         = "PT15M"
  auto_mitigate       = true
  tags                = var.tags

  criteria {
    metric_namespace = each.value.namespace
    metric_name      = each.value.metric
    aggregation      = each.value.aggregation
    operator         = each.value.operator
    threshold        = each.value.threshold
  }

  action {
    action_group_id = var.action_group_id
  }
}

# Safety net independent of in-cluster Prometheus: ERROR-level JSON log lines
# from the API containers, via Container Insights.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "app_errors" {
  name                    = "alert-${var.name_prefix}-app-errors"
  resource_group_name     = var.resource_group_name
  location                = var.location
  scopes                  = [var.log_analytics_workspace_id]
  description             = "Sortie Tracker logged more than ${var.app_error_threshold} ERROR lines in 5 minutes. Run scripts/log_analyzer.py --log-analytics for triage."
  severity                = 2
  evaluation_frequency    = "PT5M"
  window_duration         = "PT5M"
  auto_mitigation_enabled = true
  tags                    = var.tags

  criteria {
    query                   = <<-KQL
      ContainerLogV2
      | where PodNamespace == "sortie-tracker" and ContainerName == "api"
      | extend entry = parse_json(tostring(LogMessage))
      | where tostring(entry.level) == "ERROR"
      | summarize errors = count() by bin(TimeGenerated, 5m), message = tostring(entry.message)
    KQL
    time_aggregation_method = "Total"
    metric_measure_column   = "errors"
    operator                = "GreaterThan"
    threshold               = var.app_error_threshold

    dimension {
      name     = "message"
      operator = "Include"
      values   = ["*"]
    }

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [var.action_group_id]
  }
}
