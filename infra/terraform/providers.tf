provider "azurerm" {
  # `subscription_id` is mandatory from azurerm v4. Left null so it falls back
  # to ARM_SUBSCRIPTION_ID, which is what both `az login` locally and the
  # azure/login OIDC action in CI already export.
  subscription_id = var.subscription_id

  features {
    resource_group {
      # The resource group is created and owned outside this configuration, so
      # Terraform must never try to delete it out from under other resources.
      prevent_deletion_if_contains_resources = true
    }

    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }

  # Note: OIDC is enabled via ARM_USE_OIDC=true in CI rather than being pinned
  # here, so the same code still runs against a local `az login` session.
}

provider "random" {}
