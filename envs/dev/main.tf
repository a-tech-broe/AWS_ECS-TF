###############################################################################
# Environment root.
#
# This file is identical across dev/staging/prod; behaviour differences come
# entirely from terraform.tfvars. That means a change proven in dev exercises
# the same code path in prod, and drift between environments has to be a
# deliberate, reviewable edit to a variable rather than an accident.
###############################################################################

locals {
  name = "${var.project}-${var.environment}"

  tags = merge(var.tags, {
    Component = "ecs-platform"
  })

  issue_certificate = var.certificate_arn == null
  certificate_arn   = local.issue_certificate ? aws_acm_certificate_validation.this[0].certificate_arn : var.certificate_arn

  # Every host header of every service that asked for DNS, flattened into one
  # record per name so two services cannot fight over the same record.
  dns_records = {
    for record in flatten([
      for svc_name, svc in var.services : [
        for host in svc.host_headers : {
          key  = host
          host = host
        }
      ] if svc.create_dns_record && svc.enable_load_balancer
    ]) : record.key => record
  }
}

###############################################################################
# Encryption
###############################################################################

module "kms" {
  source = "../../modules/kms"

  alias       = "${local.name}-platform"
  description = "Platform key for ${local.name}: log groups, ECS Exec sessions, alarm topic"

  enable_cloudwatch_logs = true

  # CloudWatch publishing to an encrypted SNS topic does not present
  # aws:SourceAccount, so the confused-deputy condition would deny it.
  service_principals              = ["sns.amazonaws.com", "cloudwatch.amazonaws.com"]
  enable_source_account_condition = false

  tags = local.tags
}

###############################################################################
# Network
###############################################################################

module "vpc" {
  source = "../../modules/vpc"

  name                    = local.name
  cidr_block              = var.vpc_cidr
  az_count                = var.az_count
  single_nat_gateway      = var.single_nat_gateway
  enable_vpc_endpoints    = var.enable_vpc_endpoints
  enable_flow_logs        = var.enable_flow_logs
  flow_log_retention_days = var.flow_log_retention_days
  kms_key_arn             = module.kms.key_arn

  tags = local.tags
}

###############################################################################
# TLS
###############################################################################

resource "aws_acm_certificate" "this" {
  count = local.issue_certificate ? 1 : 0

  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = "DNS"

  tags = merge(local.tags, { Name = local.name })

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = var.domain_name != null && var.route53_zone_id != null
      error_message = "Set certificate_arn to reuse an existing certificate, or set both domain_name and route53_zone_id so one can be issued and DNS-validated."
    }
  }
}

resource "aws_route53_record" "certificate_validation" {
  for_each = local.issue_certificate ? {
    for opt in aws_acm_certificate.this[0].domain_validation_options :
    opt.domain_name => opt
  } : {}

  zone_id         = var.route53_zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count = local.issue_certificate ? 1 : 0

  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.certificate_validation : r.fqdn]
}

###############################################################################
# Edge
###############################################################################

module "alb" {
  source = "../../modules/alb"

  name       = "${local.name}-alb"
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnet_ids

  certificate_arn     = local.certificate_arn
  ingress_cidr_blocks = var.alb_ingress_cidr_blocks
  idle_timeout        = var.alb_idle_timeout

  enable_deletion_protection       = var.alb_deletion_protection
  access_logs_retention_days       = var.access_logs_retention_days
  access_logs_bucket_force_destroy = var.alb_logs_force_destroy

  tags = local.tags
}

module "waf" {
  source = "../../modules/waf"
  count  = var.enable_waf ? 1 : 0

  name = local.name

  # Keyed map, not a list: the ALB ARN is unknown until apply and Terraform
  # needs association instance keys to be known at plan time.
  resource_arns = { alb = module.alb.arn }

  count_mode            = var.waf_count_mode
  rate_limit            = var.waf_rate_limit
  blocked_country_codes = var.waf_blocked_country_codes
  allowed_ip_addresses  = var.waf_allowed_ip_addresses
  blocked_ip_addresses  = var.waf_blocked_ip_addresses

  log_retention_days = var.log_retention_days
  kms_key_arn        = module.kms.key_arn

  tags = local.tags
}

###############################################################################
# Cluster
###############################################################################

module "ecs_cluster" {
  source = "../../modules/ecs-cluster"

  name                    = local.name
  vpc_id                  = module.vpc.vpc_id
  container_insights_mode = var.container_insights_mode
  kms_key_arn             = module.kms.key_arn
  exec_log_retention_days = var.exec_log_retention_days

  default_capacity_provider_strategy = var.default_capacity_provider_strategy
  enable_service_connect_namespace   = var.enable_service_connect_namespace

  tags = local.tags
}

###############################################################################
# Observability
###############################################################################

module "observability" {
  source = "../../modules/observability"

  name        = local.name
  environment = var.environment
  aws_region  = var.aws_region

  cluster_name     = module.ecs_cluster.cluster_name
  alb_arn_suffix   = module.alb.arn_suffix
  service_names    = keys(var.services)
  waf_web_acl_name = var.enable_waf ? module.waf[0].web_acl_name : null

  enable_alb_monitoring = true
  enable_waf_monitoring = var.enable_waf

  kms_key_arn               = module.kms.key_arn
  alarm_email_subscriptions = var.alarm_email_subscriptions
  alarm_https_subscriptions = var.alarm_https_subscriptions
  create_dashboard          = var.create_dashboard

  tags = local.tags
}

###############################################################################
# Services
###############################################################################

module "service" {
  source   = "../../modules/ecs-service"
  for_each = var.services

  name         = each.key
  cluster_arn  = module.ecs_cluster.cluster_arn
  cluster_name = module.ecs_cluster.cluster_name
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnet_ids

  # Container
  image                    = each.value.image
  container_port           = each.value.container_port
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  cpu_architecture         = each.value.cpu_architecture
  command                  = each.value.command
  entrypoint               = each.value.entrypoint
  environment              = each.value.environment
  secrets                  = each.value.secrets
  readonly_root_filesystem = each.value.readonly_root_filesystem
  container_user           = each.value.container_user
  writable_volumes         = each.value.writable_volumes
  stop_timeout             = each.value.stop_timeout
  container_health_check   = each.value.container_health_check

  additional_container_definitions = each.value.additional_container_definitions

  # Routing
  enable_load_balancer   = each.value.enable_load_balancer
  listener_arn           = module.alb.https_listener_arn
  alb_security_group_id  = module.alb.security_group_id
  alb_arn_suffix         = module.alb.arn_suffix
  listener_rule_priority = each.value.listener_rule_priority
  host_headers           = each.value.host_headers
  path_patterns          = each.value.path_patterns
  deregistration_delay   = each.value.deregistration_delay

  target_group_protocol_version     = each.value.target_group_protocol_version
  health_check_grace_period_seconds = each.value.health_check_grace_period_seconds

  health_check = {
    path     = each.value.health_check_path
    matcher  = each.value.health_check_matcher
    interval = each.value.health_check_interval
  }

  # Capacity
  desired_count              = each.value.desired_count
  min_capacity               = each.value.min_capacity
  max_capacity               = each.value.max_capacity
  cpu_target_value           = each.value.cpu_target_value
  memory_target_value        = each.value.memory_target_value
  request_count_target_value = each.value.request_count_target_value
  scheduled_scaling          = each.value.scheduled_scaling
  capacity_provider_strategy = each.value.capacity_provider_strategy

  # Platform
  enable_service_connect = each.value.enable_service_connect
  enable_execute_command = each.value.enable_execute_command
  task_role_policy_json  = each.value.task_role_policy_json
  wait_for_steady_state  = each.value.wait_for_steady_state
  log_retention_days     = coalesce(each.value.log_retention_days, var.log_retention_days)
  kms_key_arn            = module.kms.key_arn

  alarm_actions = [module.observability.alarm_topic_arn]

  tags = merge(local.tags, { Service = each.key })
}

###############################################################################
# DNS
###############################################################################

resource "aws_route53_record" "service" {
  for_each = var.route53_zone_id != null ? local.dns_records : {}

  zone_id = var.route53_zone_id
  name    = each.value.host
  type    = "A"

  alias {
    name                   = module.alb.dns_name
    zone_id                = module.alb.zone_id
    evaluate_target_health = true
  }
}
