output "resource_group_name" {
  description = "Resource group hosting the stack."
  value       = data.azurerm_resource_group.main.name
}

output "location" {
  description = "Azure region."
  value       = data.azurerm_resource_group.main.location
}

output "aks_cluster_name" {
  description = "AKS cluster name - feed to `az aks get-credentials`."
  value       = azurerm_kubernetes_cluster.main.name
}

output "aks_node_resource_group" {
  description = "AKS-managed resource group holding nodes, disks and load balancers."
  value       = azurerm_kubernetes_cluster.main.node_resource_group
}

output "aks_oidc_issuer_url" {
  description = "Cluster OIDC issuer, used when federating workload identities for pods."
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "acr_name" {
  description = "ACR resource name - the argument to `az acr login --name`."
  value       = azurerm_container_registry.main.name
}

output "acr_login_server" {
  description = "Registry hostname used as the image prefix."
  value       = azurerm_container_registry.main.login_server
}

output "kubelet_identity_object_id" {
  description = "Object id of the kubelet identity that holds AcrPull."
  value       = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace backing Container Insights, if enabled."
  value       = var.enable_monitoring ? azurerm_log_analytics_workspace.main[0].id : null
}

/**
 * Deliberately NOT output: kube_config / kube_admin_config.
 *
 * Those attributes contain cluster credentials and would be written to the
 * state file in plaintext and printed by `terraform output`. Access is
 * obtained through `az aks get-credentials` against the Entra ID identity
 * instead, which is auditable and revocable.
 */

output "deployment_summary" {
  description = "Everything the CD workflow needs, in one object."
  value = {
    cluster        = azurerm_kubernetes_cluster.main.name
    resource_group = data.azurerm_resource_group.main.name
    acr_name       = azurerm_container_registry.main.name
    acr_server     = azurerm_container_registry.main.login_server
    image_repo     = "${azurerm_container_registry.main.login_server}/${var.project}"
  }
}
