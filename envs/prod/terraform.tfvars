###############################################################################
# prod.
#
# Every setting that trades cost for resilience is resolved in favour of
# resilience here: NAT per AZ, three AZs, on-demand capacity floor, deletion
# protection on, long log retention.
###############################################################################

aws_region  = "us-east-1"
project     = "ecs-platform"
environment = "prod"

# --- Network ------------------------------------------------------------------
vpc_cidr                = "10.30.0.0/16"
az_count                = 3
single_nat_gateway      = false # per-AZ NAT: one AZ losing egress must not affect the others
enable_vpc_endpoints    = true
flow_log_retention_days = 365

# --- TLS / DNS ----------------------------------------------------------------
# domain_name               = "example.com"
# subject_alternative_names = ["*.example.com"]
# route53_zone_id           = "Z0123456789ABCDEFGHIJ"
certificate_arn = null

# --- Edge ---------------------------------------------------------------------
alb_deletion_protection    = true
alb_logs_force_destroy     = false
access_logs_retention_days = 365

enable_waf     = true
waf_count_mode = false
waf_rate_limit = 2000

# --- Cluster ------------------------------------------------------------------
container_insights_mode = "enhanced"
log_retention_days      = 90
exec_log_retention_days = 365

# On-demand baseline covers steady state; Spot absorbs the peaks at lower cost.
default_capacity_provider_strategy = [
  { capacity_provider = "FARGATE", weight = 1, base = 2 },
  { capacity_provider = "FARGATE_SPOT", weight = 1, base = 0 },
]

# --- Alerting -----------------------------------------------------------------
# Route these somewhere that actually pages a human.
# alarm_email_subscriptions = ["platform-oncall@example.com"]
# alarm_https_subscriptions = ["https://events.pagerduty.com/integration/<key>/enqueue"]

# --- Services -----------------------------------------------------------------
services = {}
