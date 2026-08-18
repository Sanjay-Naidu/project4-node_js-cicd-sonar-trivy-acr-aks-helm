/**
 * Log Analytics workspace backing Container Insights.
 *
 * The daily quota is the important line here. Container Insights bills per GB
 * ingested and a crash-looping pod writing to stdout can generate gigabytes in
 * hours - on a fixed trial credit that is the most likely way to lose the
 * subscription. The cap makes the worst case bounded and predictable at the
 * cost of dropping logs once it is hit.
 */

resource "azurerm_log_analytics_workspace" "main" {
  count = var.enable_monitoring ? 1 : 0

  name                = local.law_name
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days
  daily_quota_gb      = var.log_analytics_daily_quota_gb
  tags                = local.common_tags
}

/**
 * Diagnostic settings on the AKS control plane.
 *
 * Node-level metrics come from Container Insights; these are the *control
 * plane* logs, which are the only way to debug "the API server rejected my
 * deployment" or to audit who changed what. kube-audit is deliberately
 * excluded - it is by far the highest-volume category and would blow the
 * daily quota on its own.
 */
resource "azurerm_monitor_diagnostic_setting" "aks" {
  count = var.enable_monitoring ? 1 : 0

  name                       = "diag-${local.aks_name}"
  target_resource_id         = azurerm_kubernetes_cluster.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main[0].id

  enabled_log {
    category = "kube-apiserver"
  }

  enabled_log {
    category = "kube-controller-manager"
  }

  enabled_log {
    category = "kube-scheduler"
  }

  enabled_log {
    category = "cluster-autoscaler"
  }

  enabled_log {
    category = "guard" # Entra ID authn/authz decisions
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
