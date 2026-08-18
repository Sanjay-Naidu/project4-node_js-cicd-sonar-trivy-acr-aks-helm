/**
 * The AKS cluster.
 *
 * Security posture worth calling out in review:
 *   * local_account_disabled - kills the static cluster-admin kubeconfig, so
 *     every kubectl call is an auditable Entra ID identity. This is what makes
 *     `--admin` credentials impossible and RBAC meaningful.
 *   * azure_rbac_enabled - Kubernetes authorisation is driven by Azure role
 *     assignments (see rbac.tf) rather than in-cluster RoleBindings nobody
 *     tracks.
 *   * workload_identity + oidc_issuer - federated pod identity, so app pods
 *     can reach Azure services with no secret mounted.
 *
 * sku_tier is Free: no financially-backed API server SLA, which is correct for
 * a demo and the single largest saving available (Standard is ~USD 73/month
 * for the control plane alone).
 */

resource "azurerm_kubernetes_cluster" "main" {
  name                = local.aks_name
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  dns_prefix          = local.aks_name
  kubernetes_version  = var.kubernetes_version
  node_resource_group = local.node_resource_group
  tags                = local.common_tags

  sku_tier = "Free"

  # Patch-level upgrades apply automatically; minor version bumps stay a
  # deliberate, reviewed change to var.kubernetes_version. Disabled on the
  # trial subscription, where there is no spare vCPU quota to surge into.
  #
  # The provider has no "none" enum member for automatic_upgrade_channel - the
  # channel is disabled by omitting it - so "none" is translated to null here.
  # Kept as a friendly string in the variable because "set it to null" is not
  # something anyone guesses from a tfvars file.
  automatic_upgrade_channel = var.automatic_upgrade_channel == "none" ? null : var.automatic_upgrade_channel
  node_os_upgrade_channel   = var.node_os_upgrade_channel

  local_account_disabled    = true
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  role_based_access_control_enabled = true

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
    # Empty is fine: rbac.tf grants the CI principal explicitly. Populate
    # var.admin_group_object_ids to add a human break-glass group.
    admin_group_object_ids = var.admin_group_object_ids
  }

  default_node_pool {
    name           = "system"
    vm_size        = var.node_vm_size
    vnet_subnet_id = azurerm_subnet.aks.id
    zones          = var.availability_zones

    auto_scaling_enabled = true
    node_count           = var.node_count
    min_count            = var.node_min_count
    max_count            = var.node_max_count

    os_disk_size_gb = var.node_os_disk_size_gb
    os_disk_type    = "Managed"
    os_sku          = "Ubuntu"
    max_pods        = 50

    # Single-pool cluster, so application pods must be schedulable here.
    # A production build would add a separate user pool and set this true.
    only_critical_addons_enabled = false

    # Surge one extra node during upgrades so a node drain never has to evict
    # below the PodDisruptionBudget.
    upgrade_settings {
      max_surge = "1"
    }

    node_labels = {
      "workload" = "system"
    }

    tags = local.common_tags
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    # Enables NetworkPolicy objects to be enforced - without this the chart's
    # NetworkPolicy would be silently inert, which is worse than not having one.
    network_policy = "azure"

    pod_cidr       = var.pod_cidr
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip

    load_balancer_sku = "standard"
    outbound_type     = "loadBalancer"
  }

  dynamic "api_server_access_profile" {
    for_each = length(var.authorized_ip_ranges) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.authorized_ip_ranges
    }
  }

  dynamic "oms_agent" {
    for_each = var.enable_monitoring ? [1] : []
    content {
      log_analytics_workspace_id      = azurerm_log_analytics_workspace.main[0].id
      msi_auth_for_monitoring_enabled = true
    }
  }

  # Lets pods mount secrets straight from Key Vault via CSI instead of holding
  # copies in etcd. Not used by the demo app, but it is the mechanism a real
  # service would use and costs nothing to enable.
  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  auto_scaler_profile {
    # Scale down quickly: idle nodes on a trial subscription are pure burn.
    scale_down_unneeded        = "5m"
    scale_down_delay_after_add = "5m"
    expander                   = "least-waste"
  }

  lifecycle {
    ignore_changes = [
      # The autoscaler owns node_count after creation; without this every plan
      # would try to reset it to the baseline and fight the scaler.
      default_node_pool[0].node_count,
    ]
  }
}
