output "metric_alert_ids" {
  value = { for k, a in azurerm_monitor_metric_alert.this : k => a.id }
}

output "app_error_alert_id" {
  value = azurerm_monitor_scheduled_query_rules_alert_v2.app_errors.id
}
