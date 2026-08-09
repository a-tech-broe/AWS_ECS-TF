###############################################################################
# Environment identity
###############################################################################

variable "aws_region" {
  description = "Region this environment is deployed to."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project slug used as a name prefix."
  type        = string
  default     = "ecs-platform"
}

variable "environment" {
  description = "Environment name. Becomes part of every resource name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{2,12}$", var.environment))
    error_message = "environment must be lowercase alphanumeric with hyphens, 2-12 characters."
  }
}

variable "repository" {
  description = "Source repository, recorded as a tag on every resource."
  type        = string
  default     = "AWS_ECS-TF"
}

###############################################################################
# Network
###############################################################################

variable "vpc_cidr" {
  description = "IPv4 CIDR for the VPC. Keep environments non-overlapping so they can be peered later."
  type        = string
}

variable "az_count" {
  description = "Availability Zones to span. Three is the production baseline."
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = "Share one NAT Gateway across AZs. Acceptable in dev, never in production."
  type        = bool
  default     = false
}

variable "enable_vpc_endpoints" {
  description = "Create interface endpoints so image pulls, logs and secrets bypass NAT."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Capture VPC Flow Logs."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Retention for VPC Flow Logs."
  type        = number
  default     = 90
}

###############################################################################
# TLS and DNS
###############################################################################

variable "certificate_arn" {
  description = "Existing ACM certificate ARN for the ALB. Leave null to have this root issue one via DNS validation."
  type        = string
  default     = null
}

variable "domain_name" {
  description = "Apex domain for this environment, e.g. 'dev.example.com'. Required when issuing a certificate."
  type        = string
  default     = null
}

variable "subject_alternative_names" {
  description = "Additional names on the issued certificate, e.g. ['*.dev.example.com']."
  type        = list(string)
  default     = []
}

variable "route53_zone_id" {
  description = "Hosted zone used for certificate validation and service ALIAS records."
  type        = string
  default     = null
}

###############################################################################
# Edge
###############################################################################

variable "alb_ingress_cidr_blocks" {
  description = "CIDRs allowed to reach the load balancer."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "alb_deletion_protection" {
  description = "Block accidental deletion of the load balancer."
  type        = bool
  default     = true
}

variable "alb_idle_timeout" {
  description = "Seconds an idle ALB connection is held open."
  type        = number
  default     = 60
}

variable "access_logs_retention_days" {
  description = "Retention for ALB access logs."
  type        = number
  default     = 90
}

variable "alb_logs_force_destroy" {
  description = "Allow Terraform to delete the ALB log bucket while it still holds objects."
  type        = bool
  default     = false
}

variable "enable_waf" {
  description = "Attach a WAFv2 web ACL to the load balancer."
  type        = bool
  default     = true
}

variable "waf_count_mode" {
  description = "Run WAF managed rules in count-only mode. Use this for the first week in a new environment, then switch to enforcing."
  type        = bool
  default     = false
}

variable "waf_rate_limit" {
  description = "Requests per five minutes from one IP before WAF blocks it."
  type        = number
  default     = 2000
}

variable "waf_blocked_country_codes" {
  description = "ISO country codes blocked at the edge."
  type        = list(string)
  default     = []
}

variable "waf_allowed_ip_addresses" {
  description = "CIDRs that bypass WAF inspection entirely."
  type        = list(string)
  default     = []
}

variable "waf_blocked_ip_addresses" {
  description = "CIDRs blocked before any other WAF rule."
  type        = list(string)
  default     = []
}

###############################################################################
# Cluster
###############################################################################

variable "container_insights_mode" {
  description = "Container Insights tier: 'enabled' or 'enhanced'."
  type        = string
  default     = "enabled"
}

variable "default_capacity_provider_strategy" {
  description = "Cluster-wide default split between FARGATE and FARGATE_SPOT."
  type = list(object({
    capacity_provider = string
    weight            = number
    base              = optional(number, 0)
  }))
  default = [
    { capacity_provider = "FARGATE", weight = 1, base = 1 },
  ]
}

variable "enable_service_connect_namespace" {
  description = "Create a Cloud Map namespace for service-to-service discovery."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Default retention for service log groups."
  type        = number
  default     = 30
}

variable "exec_log_retention_days" {
  description = "Retention for the ECS Exec audit trail. Keep this long; it is an access audit record."
  type        = number
  default     = 365
}

###############################################################################
# Alerting
###############################################################################

variable "alarm_email_subscriptions" {
  description = "Email addresses subscribed to the alarm topic. Each recipient must confirm the subscription."
  type        = list(string)
  default     = []
}

variable "alarm_https_subscriptions" {
  description = "HTTPS endpoints subscribed to the alarm topic, e.g. a PagerDuty ingest URL."
  type        = list(string)
  default     = []
}

variable "create_dashboard" {
  description = "Create the CloudWatch dashboard for this environment."
  type        = bool
  default     = true
}

###############################################################################
# Services
###############################################################################

variable "services" {
  description = <<-EOT
    Applications to deploy. The key becomes the service name, log group and IAM
    role prefix. `listener_rule_priority` must be unique across all services.
    Pin `image` to an immutable tag or digest so a rollback is deterministic.
  EOT

  type = map(object({
    image            = string
    container_port   = optional(number, 8080)
    cpu              = optional(number, 512)
    memory           = optional(number, 1024)
    cpu_architecture = optional(string, "X86_64")
    command          = optional(list(string))
    entrypoint       = optional(list(string))

    environment = optional(map(string), {})
    secrets     = optional(map(string), {})

    readonly_root_filesystem = optional(bool, true)
    container_user           = optional(string, "1000:1000")
    writable_volumes         = optional(map(string), {})
    stop_timeout             = optional(number, 30)

    container_health_check = optional(object({
      command      = list(string)
      interval     = optional(number, 30)
      timeout      = optional(number, 5)
      retries      = optional(number, 3)
      start_period = optional(number, 30)
    }))

    # Routing
    enable_load_balancer              = optional(bool, true)
    listener_rule_priority            = optional(number, 100)
    host_headers                      = optional(list(string), [])
    path_patterns                     = optional(list(string), [])
    health_check_path                 = optional(string, "/healthz")
    health_check_matcher              = optional(string, "200")
    health_check_interval             = optional(number, 15)
    deregistration_delay              = optional(number, 30)
    health_check_grace_period_seconds = optional(number, 60)
    target_group_protocol_version     = optional(string, "HTTP1")
    create_dns_record                 = optional(bool, false)

    # Capacity
    desired_count              = optional(number, 2)
    min_capacity               = optional(number, 2)
    max_capacity               = optional(number, 10)
    cpu_target_value           = optional(number, 65)
    memory_target_value        = optional(number, 75)
    request_count_target_value = optional(number)

    scheduled_scaling = optional(list(object({
      name         = string
      schedule     = string
      min_capacity = number
      max_capacity = number
      timezone     = optional(string, "UTC")
    })), [])

    capacity_provider_strategy = optional(list(object({
      capacity_provider = string
      weight            = number
      base              = optional(number, 0)
    })), [])

    # Platform integration
    enable_service_connect = optional(bool, false)
    enable_execute_command = optional(bool, true)
    task_role_policy_json  = optional(string)
    log_retention_days     = optional(number)
    wait_for_steady_state  = optional(bool, true)

    additional_container_definitions = optional(any, [])
  }))

  default = {}

  validation {
    condition = length(distinct([
      for k, s in var.services : s.listener_rule_priority if s.enable_load_balancer
      ])) == length([
      for k, s in var.services : s.listener_rule_priority if s.enable_load_balancer
    ])
    error_message = "Each load-balanced service needs a unique listener_rule_priority."
  }

  validation {
    condition = alltrue([
      for k, s in var.services :
      !s.enable_load_balancer || length(s.host_headers) > 0 || length(s.path_patterns) > 0
    ])
    error_message = "Every load-balanced service needs at least one host_header or path_pattern."
  }

  validation {
    condition     = alltrue([for k, s in var.services : !strcontains(s.image, ":latest")])
    error_message = "Pin images to an immutable tag or digest; ':latest' makes deploys and rollbacks non-deterministic."
  }
}

variable "tags" {
  description = "Additional tags applied to every resource in this environment."
  type        = map(string)
  default     = {}
}
