variable "subscription_id" {
  description = "Target Azure subscription id. Leave null to inherit ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "resource_group_name" {
  description = "Name of the PRE-EXISTING resource group. Created manually, consumed here as a data source, and never managed by this configuration."
  type        = string
}

variable "project" {
  description = "Short project slug used to build resource names."
  type        = string
  default     = "ordersapi"

  validation {
    # Flows into the ACR name, which permits alphanumerics only.
    condition     = can(regex("^[a-z0-9]{3,12}$", var.project))
    error_message = "project must be 3-12 lowercase alphanumeric characters (it is used to build the ACR name)."
  }
}

variable "environment" {
  description = "Environment slug (dev/stage/prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be one of: dev, stage, prod."
  }
}

variable "location" {
  description = "Azure region. Keep this consistent with the region your trial subscription has vCPU quota in."
  type        = string
  default     = "eastus"
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "vnet_address_space" {
  description = "Address space for the cluster VNet."
  type        = list(string)
  default     = ["10.20.0.0/16"]
}

variable "aks_subnet_prefix" {
  description = "Subnet the AKS nodes live in. With CNI Overlay this only needs to be large enough for nodes, not pods."
  type        = string
  default     = "10.20.1.0/24"
}

variable "pod_cidr" {
  description = "Overlay pod CIDR. Must not overlap the VNet or service CIDR."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes Service CIDR. Must not overlap the VNet or pod CIDR."
  type        = string
  default     = "10.0.0.0/16"
}

variable "dns_service_ip" {
  description = "CoreDNS Service IP. Must sit inside service_cidr."
  type        = string
  default     = "10.0.0.10"
}

# ---------------------------------------------------------------------------
# AKS
# ---------------------------------------------------------------------------

variable "kubernetes_version" {
  description = "AKS control plane version. Null tracks the region's current default, which avoids pinning to a version Azure has since retired."
  type        = string
  default     = null
}

variable "automatic_upgrade_channel" {
  description = <<-EOT
    AKS patch upgrade channel. "patch" is the right production answer, but an
    upgrade surges an extra node (see max_surge) and therefore needs spare
    regional vCPU quota. On a free-trial subscription capped at 4 vCPUs - which
    2 x Standard_D2as_v7 consumes entirely - a surge cannot be satisfied and
    the upgrade fails, so dev sets this to "none".
  EOT
  # "none" is not a provider enum member; aks.tf translates it to null, which is
  # how the API expresses "no automatic upgrades".
  type    = string
  default = "patch"

  validation {
    condition     = contains(["none", "patch", "rapid", "stable", "node-image"], var.automatic_upgrade_channel)
    error_message = "automatic_upgrade_channel must be one of: none, patch, rapid, stable, node-image."
  }
}

variable "node_os_upgrade_channel" {
  description = "Node OS image upgrade channel. Set to None alongside automatic_upgrade_channel when vCPU quota leaves no room to surge."
  type        = string
  default     = "NodeImage"
}

variable "node_vm_size" {
  description = <<-EOT
    Node SKU. Must satisfy the AKS system-pool minimum of 2 vCPU / 4 GiB AND be
    permitted on the subscription - those are different checks. Many trial and
    MSDN subscriptions block burstable B-series entirely, which surfaces only at
    create time as "The VM size ... is not allowed in your subscription".
    Confirm with:
      az vm list-skus --location <region> --size <sku> --query "[].restrictions"
  EOT
  type        = string
  default     = "Standard_D2as_v7"
}

variable "node_count" {
  description = "Baseline node count. Two nodes is the minimum that lets a PodDisruptionBudget actually hold during a node drain."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 2
    error_message = "node_count must be at least 2 so pod anti-affinity and the PDB can be satisfied."
  }
}

variable "node_min_count" {
  description = "Cluster autoscaler floor."
  type        = number
  default     = 2
}

variable "node_max_count" {
  description = "Cluster autoscaler ceiling. Keep low on a trial subscription: each node consumes regional vCPU quota and burns credit."
  type        = number
  default     = 3
}

variable "node_os_disk_size_gb" {
  description = "Managed OS disk per node. Ephemeral OS disks would be free of charge but need a cache at least as large as the image, which constrains SKU choice - not worth the coupling here."
  type        = number
  default     = 64
}

variable "availability_zones" {
  description = <<-EOT
    Zones to spread nodes across. Defaults to [] because trial subscriptions
    frequently have no zonal capacity for the SKUs they permit, and a zonal
    request that cannot be satisfied fails the whole apply. Set to
    ["1","2","3"] on a subscription with real capacity for a genuinely
    production topology.
  EOT
  type        = list(string)
  default     = []
}

variable "admin_group_object_ids" {
  description = "Entra ID group object ids granted cluster-admin via Azure RBAC. Optional; the CI principal is granted access separately."
  type        = list(string)
  default     = []
}

variable "cicd_principal_object_id" {
  description = <<-EOT
    Object id (NOT application/client id) of the service principal GitHub
    Actions federates into. Leave empty on the first apply, then supply it once
    the app registration exists to have Terraform grant AcrPush + AKS RBAC
    Cluster Admin. Look it up with:
      az ad sp show --id <APP_CLIENT_ID> --query id -o tsv
  EOT
  type        = string
  default     = ""
}

variable "authorized_ip_ranges" {
  description = <<-EOT
    CIDRs allowed to reach the Kubernetes API server. Empty means public.
    GitHub-hosted runners use a large, rotating IP range, so locking this down
    requires either a self-hosted runner or syncing GitHub's published ranges -
    documented in docs/RUNBOOK.md rather than half-configured here.
  EOT
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

variable "acr_sku" {
  description = "ACR tier. Basic is ~USD 5/month and sufficient here; Premium is required for private endpoints, geo-replication and image retention policies."
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.acr_sku)
    error_message = "acr_sku must be Basic, Standard or Premium."
  }
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

variable "enable_monitoring" {
  description = "Deploy Log Analytics + Container Insights. Set false to shave roughly USD 10/month off a trial subscription."
  type        = bool
  default     = true
}

variable "log_analytics_retention_days" {
  description = "Log retention. 30 days is the minimum billable retention."
  type        = number
  default     = 30
}

variable "log_analytics_daily_quota_gb" {
  description = "Hard daily ingestion cap. This is the single most effective guard against a log loop quietly draining the subscription credit."
  type        = number
  default     = 0.2
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
