/**
 * Shared locals, the pre-existing resource group, and naming.
 *
 * The resource group is intentionally a data source: it is created by hand
 * (often the only thing an engineer is permitted to create on a locked-down
 * subscription) and this configuration is only ever a tenant inside it. That
 * also means `terraform destroy` tears down the workload without touching the
 * container it lives in.
 */

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

# ACR names share one global namespace and allow alphanumerics only, so a
# stable random suffix is generated once and kept in state forever.
resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  # Azure CAF-style naming: <type>-<project>-<env>-<region>
  name_prefix = "${var.project}-${var.environment}"

  aks_name  = "aks-${local.name_prefix}"
  acr_name  = "acr${var.project}${var.environment}${random_string.suffix.result}"
  law_name  = "log-${local.name_prefix}"
  vnet_name = "vnet-${local.name_prefix}"

  # AKS creates its own "infrastructure" resource group for node VMs, disks and
  # load balancers. Naming it explicitly keeps the portal legible.
  node_resource_group = "rg-${local.name_prefix}-nodes"

  common_tags = merge(
    {
      project     = var.project
      environment = var.environment
      managedBy   = "terraform"
      owner       = "Sanjay-Naidu"
      repository  = "project4-node_js-cicd-sonar-trivy-acr-aks-helm"
      # Cost guard rail: this stack is meant to be short-lived on a trial
      # subscription. The tag makes an orphaned cluster obvious in Cost
      # Analysis instead of quietly billing for a month.
      lifecycle = "ephemeral-demo"
    },
    var.tags,
  )
}
