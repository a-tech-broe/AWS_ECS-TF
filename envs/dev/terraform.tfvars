###############################################################################
# dev — optimised for cost and iteration speed, not for surviving an AZ loss.
###############################################################################

aws_region  = "us-east-1"
project     = "ecs-platform"
environment = "dev"

# --- Network ------------------------------------------------------------------
vpc_cidr                = "10.10.0.0/16"
az_count                = 2
single_nat_gateway      = true # ~$32/month saved; unacceptable in prod
enable_vpc_endpoints    = true
flow_log_retention_days = 14

# --- TLS / DNS ----------------------------------------------------------------
# The hosted zone is created once by envs/shared and looked up here by name, so
# the zone ID never has to be copied between environments. A certificate for
# these names is issued and DNS-validated automatically.
#
# This cannot succeed until skybroe.com's registrar delegates NS records to that
# zone; without delegation the apply waits out certificate_validation_timeout
# and fails.
route53_zone_name         = "skybroe.com"
domain_name               = "dev.skybroe.com"
subject_alternative_names = ["*.dev.skybroe.com"]

# --- Edge ---------------------------------------------------------------------
alb_deletion_protection    = false
alb_logs_force_destroy     = true
access_logs_retention_days = 30

enable_waf     = true
waf_count_mode = false
waf_rate_limit = 5000

# --- Cluster ------------------------------------------------------------------
container_insights_mode = "enabled"
log_retention_days      = 14
exec_log_retention_days = 90

# Dev runs entirely on Spot: interruptions are a useful forcing function for
# making services genuinely restart-tolerant before they reach production.
default_capacity_provider_strategy = [
  { capacity_provider = "FARGATE_SPOT", weight = 1, base = 0 },
]

# --- Alerting -----------------------------------------------------------------
# alarm_email_subscriptions = ["platform-team@example.com"]

# --- Services -----------------------------------------------------------------
# Uncomment and adjust once an image exists in ECR. Until then the platform
# deploys with no workloads, which is a valid and useful state.
services = {}

# services = {
#   api = {
#     image                  = "<account-id>.dkr.ecr.us-east-1.amazonaws.com/ecs-platform/api:v1.0.0"
#     container_port         = 8080
#     cpu                    = 512
#     memory                 = 1024
#     desired_count          = 1
#     min_capacity           = 1
#     max_capacity           = 4
#     listener_rule_priority = 100
#     host_headers           = ["api.dev.skybroe.com"]
#     health_check_path      = "/healthz"
#     create_dns_record      = true
#
#     environment = {
#       LOG_LEVEL = "debug"
#     }
#
#     secrets = {
#       DATABASE_URL = "arn:aws:secretsmanager:us-east-1:<account-id>:secret:dev/api/database-AbCdEf"
#     }
#   }
# }
