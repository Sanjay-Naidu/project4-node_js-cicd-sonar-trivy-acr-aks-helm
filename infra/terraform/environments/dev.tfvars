# Dev / trial-subscription profile.
#
# TWO HARD CONSTRAINTS on this subscription, and every setting below follows
# from them:
#
# 1. Total Regional vCPU quota is 4 in eastus. At 2 vCPU per node that is
#    exactly two nodes, with nothing spare.
#
# 2. Burstable (B-series) SKUs are NOT PERMITTED on this subscription. This is
#    a subscription policy, not a quota - `az vm list-usage` cheerfully reports
#    "Standard BS Family vCPUs: limit 4" while AKS rejects the create with
#    "The VM size of Standard_B2s is not allowed in your subscription".
#    Quota and SKU permission are separate things; check both.
#
# Standard_D2as_v7 is the cheapest permitted SKU meeting the AKS system-pool
# minimum of 2 vCPU / 4 GiB (it has 8 GiB, giving real headroom for the
# ingress controller and Container Insights alongside the app).

resource_group_name = "rg-ordersapi-dev"
project             = "ordersapi"
environment         = "dev"
location            = "eastus"

node_vm_size = "Standard_D2as_v7"

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

# Trial subscriptions frequently have no zonal capacity, and an unsatisfiable
# zonal request fails the entire apply.
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
