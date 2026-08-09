variable "name" {
  description = "Name prefix for the topic, alarms and dashboard."
  type        = string
}

variable "environment" {
  description = "Environment name shown on the dashboard."
  type        = string
}

variable "aws_region" {
  description = "Region whose metrics the dashboard renders."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN encrypting the SNS topic."
  type        = string
  default     = null
}

variable "alarm_email_subscriptions" {
  description = "Email addresses subscribed to the alarm topic. Each requires manual confirmation from the recipient."
  type        = list(string)
  default     = []
}

variable "alarm_https_subscriptions" {
  description = "HTTPS endpoints subscribed to the alarm topic, e.g. PagerDuty or Opsgenie ingest URLs."
  type        = list(string)
  default     = []
}

variable "cluster_name" {
  description = "ECS cluster name for cluster-level alarms and dashboard widgets."
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix for load balancer alarms and widgets. Unknown until apply, so it is used only as a value, never to decide whether a resource exists."
  type        = string
  default     = null
}

variable "enable_alb_monitoring" {
  description = "Create load balancer alarms and widgets. Must be statically known, unlike alb_arn_suffix."
  type        = bool
  default     = true
}

variable "enable_waf_monitoring" {
  description = "Create WAF alarms and widgets. Must be statically known, unlike waf_web_acl_name."
  type        = bool
  default     = false
}

variable "service_names" {
  description = "ECS service names rendered on the dashboard."
  type        = list(string)
  default     = []
}

variable "waf_web_acl_name" {
  description = "WAF web ACL name for blocked-request widgets and alarms."
  type        = string
  default     = null
}

variable "alb_5xx_threshold" {
  description = "Load balancer generated 5xx responses per period before alarming. These are ALB faults, not application errors."
  type        = number
  default     = 5
}

variable "alb_target_5xx_threshold" {
  description = "Aggregate target 5xx responses per period before alarming."
  type        = number
  default     = 25
}

variable "alb_rejected_connections_threshold" {
  description = "Rejected connections per period before alarming. Non-zero means the ALB is out of surge capacity."
  type        = number
  default     = 0
}

variable "waf_blocked_requests_threshold" {
  description = "Blocked requests per period before alarming, as a signal of an attack in progress."
  type        = number
  default     = 1000
}

variable "alarm_period_seconds" {
  description = "Evaluation period for platform alarms."
  type        = number
  default     = 60
}

variable "evaluation_periods" {
  description = "Consecutive periods evaluated before an alarm fires."
  type        = number
  default     = 2
}

variable "create_dashboard" {
  description = "Create the CloudWatch dashboard."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}
