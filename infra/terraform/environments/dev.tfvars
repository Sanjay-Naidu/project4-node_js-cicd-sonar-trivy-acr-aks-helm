# Dev / trial-subscription profile.
#
# HARD CONSTRAINT: this subscription has a Total Regional vCPU quota of 4 in
# eastus (verified with `az vm list-usage --location eastus`). Standard_B2s is
# 2 vCPU and is already the smallest SKU AKS accepts for a system pool, so
# 2 nodes consumes the entire quota. Every setting below follows from that.

resource_group_name = "rg-ordersapi-dev"
project             = "ordersapi"
environment         = "dev"
location            = "eastus"

node_vm_size = "Standard_B2s"

# 2 x 2 vCPU = 4 = the whole regional quota. min == max because the cluster
# autoscaler has nowhere to grow: a third node would need 6 vCPU and every
# scale-out would fail with a quota error. The HPA still scales pods, which is
# the part the demo actually shows.
node_count     = 2
node_min_count = 2
node_max_count = 2

# An upgrade surges one extra node (max_surge = 1) and would need 6 vCPU, so
# automatic upgrades are turned off here rather than left to fail silently.
# Production keeps them on - see prod.tfvars.
automatic_upgrade_channel = "none"
node_os_upgrade_channel   = "None"

# Burstable SKUs frequently have no zonal capacity on trial subscriptions, and
# an unsatisfiable zonal request fails the entire apply.
availability_zones = []

acr_sku = "Basic"

enable_monitoring            = true
log_analytics_daily_quota_gb = 0.2
log_analytics_retention_days = 30

# NOTE: cicd_principal_object_id is deliberately NOT set here.
#
# This file is committed to a public repository, and the service principal
# object id is tenant-identifying information. It is supplied instead through
# the TF_VAR_cicd_principal_object_id environment variable, sourced from the
# AZURE_CICD_PRINCIPAL_OBJECT_ID repository variable in CI, or from a
# gitignored dev.auto.tfvars locally.
#
# It must not be declared here even as "": a value in a -var-file takes
# precedence over a TF_VAR_ environment variable, so an empty string here
# would silently override the real value and skip the role assignments.

tags = {
  owner      = "sanjay"
  costCenter = "personal-learning"
}
