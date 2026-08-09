###############################################################################
# staging — production-shaped, at reduced scale. Its job is to make a prod
# deploy boring, so the topology matches prod even where the capacity does not.
###############################################################################

aws_region  = "us-east-1"
project     = "ecs-platform"
environment = "staging"

# --- Network ------------------------------------------------------------------
vpc_cidr                = "10.20.0.0/16"
az_count                = 3
single_nat_gateway      = false
enable_vpc_endpoints    = true
flow_log_retention_days = 30

# --- TLS / DNS ----------------------------------------------------------------
# The hosted zone is created once by envs/shared and looked up here by name, so
# the zone ID never has to be copied between environments. A certificate for
# these names is issued and DNS-validated automatically.
#
# This cannot succeed until skybroe.com's registrar delegates NS records to that
# zone; without delegation the apply waits out certificate_validation_timeout
# and fails.
route53_zone_name         = "skybroe.com"
domain_name               = "staging.skybroe.com"
subject_alternative_names = ["*.staging.skybroe.com"]

# --- Edge ---------------------------------------------------------------------
alb_deletion_protection    = true
alb_logs_force_destroy     = false
access_logs_retention_days = 90

enable_waf     = true
waf_count_mode = false
waf_rate_limit = 3000

# --- Cluster ------------------------------------------------------------------
container_insights_mode = "enabled"
log_retention_days      = 30
exec_log_retention_days = 365

# Mostly Spot, with one guaranteed on-demand task so the service never drops to
# zero capacity during a Spot reclamation event.
default_capacity_provider_strategy = [
  { capacity_provider = "FARGATE", weight = 1, base = 1 },
  { capacity_provider = "FARGATE_SPOT", weight = 3, base = 0 },
]

# --- Alerting -----------------------------------------------------------------
# alarm_email_subscriptions = ["platform-team@example.com"]

# --- Services -----------------------------------------------------------------
services = {}
