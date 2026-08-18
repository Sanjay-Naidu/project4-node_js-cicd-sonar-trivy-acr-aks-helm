/**
 * Role assignments - the part that replaces every stored credential.
 *
 * Two distinct identities are involved and conflating them is a common mistake:
 *
 *   kubelet identity  - the cluster's own managed identity. Needs AcrPull so
 *                       nodes can pull images. Nothing to do with CI.
 *   CI principal      - the Entra app registration GitHub Actions federates
 *                       into via OIDC. Needs AcrPush to publish images and AKS
 *                       RBAC to run helm upgrade. Holds no secret at all.
 */

# --------------------------------------------------------------------------
# Cluster -> registry: nodes pull images with the kubelet's managed identity.
# --------------------------------------------------------------------------
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id

  # The role definition is a well-known built-in, so skip the Entra lookup that
  # otherwise fails intermittently on freshly created principals.
  skip_service_principal_aad_check = true
}

# --------------------------------------------------------------------------
# CI -> registry: push images.
# --------------------------------------------------------------------------
resource "azurerm_role_assignment" "cicd_acr_push" {
  count = var.cicd_principal_object_id != "" ? 1 : 0

  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPush"
  principal_id                     = var.cicd_principal_object_id
  skip_service_principal_aad_check = true
}

# --------------------------------------------------------------------------
# CI -> cluster.
#
# Two roles are required and each does exactly one thing:
#   "Azure Kubernetes Service Cluster User Role" -> permission to *fetch* a
#       kubeconfig (`az aks get-credentials`). It grants no in-cluster rights.
#   "Azure Kubernetes Service RBAC Cluster Admin" -> the actual in-cluster
#       authorisation, enforced by the API server because azure_rbac_enabled.
#
# Cluster Admin is broader than a deployment strictly needs. It is scoped to
# this one cluster, and the narrower alternative is the "RBAC Writer" role
# scoped to a single namespace - see docs/RUNBOOK.md for that variant.
# --------------------------------------------------------------------------
resource "azurerm_role_assignment" "cicd_aks_cluster_user" {
  count = var.cicd_principal_object_id != "" ? 1 : 0

  scope                            = azurerm_kubernetes_cluster.main.id
  role_definition_name             = "Azure Kubernetes Service Cluster User Role"
  principal_id                     = var.cicd_principal_object_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "cicd_aks_rbac_admin" {
  count = var.cicd_principal_object_id != "" ? 1 : 0

  scope                            = azurerm_kubernetes_cluster.main.id
  role_definition_name             = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id                     = var.cicd_principal_object_id
  skip_service_principal_aad_check = true
}

# --------------------------------------------------------------------------
# Cluster -> networking.
#
# The cluster identity programs the Standard Load Balancer and public IPs that
# back both the LoadBalancer Service and the ingress controller. Those live in
# the AKS-managed node resource group, where AKS grants itself rights; this
# assignment covers the *custom* VNet, which lives in our resource group and
# which AKS therefore has no implicit access to.
# --------------------------------------------------------------------------
resource "azurerm_role_assignment" "aks_network_contributor" {
  scope                            = azurerm_virtual_network.main.id
  role_definition_name             = "Network Contributor"
  principal_id                     = azurerm_kubernetes_cluster.main.identity[0].principal_id
  skip_service_principal_aad_check = true
}
