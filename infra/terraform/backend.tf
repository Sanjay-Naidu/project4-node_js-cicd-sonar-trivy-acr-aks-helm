/**
 * Remote state.
 *
 * Deliberately a *partial* configuration: no storage account name, container
 * or subscription id is committed. Values are supplied at init time so the
 * same code can target different state backends, and so nothing about the
 * state location leaks into a public repository:
 *
 *   terraform init -backend-config=backend.hcl
 *
 * Authentication uses Entra ID (OIDC in CI, `az login` locally) rather than a
 * storage account access key - see use_azuread_auth below. That means there is
 * no shared secret to rotate or leak, and access is governed by the
 * "Storage Blob Data Contributor" role assignment on the container.
 */
terraform {
  backend "azurerm" {
    # Supplied via -backend-config:
    #   resource_group_name  = "..."
    #   storage_account_name = "..."
    #   container_name       = "tfstate"
    #   key                  = "orders-api/dev.terraform.tfstate"

    # Data-plane calls authenticate with an Entra ID token, never a shared key.
    use_azuread_auth = true
  }
}
