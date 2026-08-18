# Production profile - NOT for the trial subscription.
#
# Kept in the repo to make the delta explicit: the same modules, the same
# pipeline, different sizing and durability guarantees. Roughly USD 400+/month,
# so do not apply this against a free-trial credit.

resource_group_name = "rg-ordersapi-prod"
project             = "ordersapi"
environment         = "prod"
location            = "eastus"

# Non-burstable SKU: B-series CPU credits make latency unpredictable under
# sustained load, which is fine for a demo and not fine for production.
node_vm_size   = "Standard_D4s_v5"
node_count     = 3
node_min_count = 3
node_max_count = 10

# Spread across all three zones so a single datacentre failure cannot take the
# whole Deployment down.
availability_zones = ["1", "2", "3"]

# Premium unlocks private endpoints, geo-replication, image retention and
# content trust.
acr_sku = "Premium"

enable_monitoring            = true
log_analytics_daily_quota_gb = 10
log_analytics_retention_days = 90

# Lock the API server down to known egress ranges - requires self-hosted
# runners or a NAT gateway in front of CI.
# authorized_ip_ranges = ["203.0.113.0/24"]

# admin_group_object_ids = ["<entra-group-object-id>"]

# Supplied via TF_VAR_cicd_principal_object_id - see the note in dev.tfvars for
# why it is not declared here.

tags = {
  owner      = "platform-team"
  costCenter = "engineering"
  compliance = "internal"
}
