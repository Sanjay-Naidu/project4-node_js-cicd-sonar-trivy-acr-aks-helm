/**
 * Azure Container Registry.
 *
 * admin_enabled is false: the admin account is a shared static username and
 * password, which is exactly the kind of long-lived credential this pipeline
 * exists to avoid. Both push (GitHub Actions, via OIDC) and pull (the AKS
 * kubelet identity, via the AcrPull assignment in rbac.tf) authenticate with
 * Entra ID tokens instead.
 */

resource "azurerm_container_registry" "main" {
  name                = local.acr_name
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  sku                 = var.acr_sku
  admin_enabled       = false
  tags                = local.common_tags

  # Basic/Standard do not support private endpoints, so the registry is
  # internet-reachable but authorisation-gated. On Premium this would be false
  # with a private endpoint into the cluster VNet.
  public_network_access_enabled = true

  # Zone redundancy and untagged-manifest retention are Premium-only features;
  # guarded so switching acr_sku to Premium turns them on without further edits.
  # null (not 0) means "not configured" - the API rejects the setting outright
  # on Basic and Standard.
  zone_redundancy_enabled  = var.acr_sku == "Premium"
  retention_policy_in_days = var.acr_sku == "Premium" ? 30 : null
}
