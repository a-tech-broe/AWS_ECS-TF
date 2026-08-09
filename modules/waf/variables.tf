variable "name" {
  description = "Name of the web ACL."
  type        = string
}

variable "resource_arns" {
  description = <<-EOT
    Regional resources to associate with this web ACL, as a map of a stable
    caller-chosen key to the resource ARN. A map rather than a list because the
    ARNs are unknown until apply, and Terraform needs the instance keys to be
    known at plan time.
  EOT
  type        = map(string)
  default     = {}
}

variable "default_action" {
  description = "What happens to a request no rule matches. 'allow' is correct for a public web ACL."
  type        = string
  default     = "allow"

  validation {
    condition     = contains(["allow", "block"], var.default_action)
    error_message = "default_action must be allow or block."
  }
}

variable "count_mode" {
  description = "Run every managed rule group in count-only mode. Use this to observe traffic for a week before enforcing, so legitimate requests are not blocked on day one."
  type        = bool
  default     = false
}

variable "managed_rule_groups" {
  description = "AWS managed rule groups to evaluate, in priority order starting at 10."
  type = list(object({
    name            = string
    vendor_name     = optional(string, "AWS")
    excluded_rules  = optional(list(string), [])
    count_overrides = optional(list(string), [])
  }))

  default = [
    { name = "AWSManagedRulesAmazonIpReputationList" },
    { name = "AWSManagedRulesCommonRuleSet" },
    { name = "AWSManagedRulesKnownBadInputsRuleSet" },
    { name = "AWSManagedRulesSQLiRuleSet" },
    { name = "AWSManagedRulesLinuxRuleSet" },
  ]
}

variable "enable_rate_limiting" {
  description = "Block source IPs that exceed the request rate threshold."
  type        = bool
  default     = true
}

variable "rate_limit" {
  description = "Requests per five-minute window from a single IP before blocking."
  type        = number
  default     = 2000

  validation {
    condition     = var.rate_limit >= 10 && var.rate_limit <= 20000000
    error_message = "rate_limit must be between 10 and 20000000."
  }
}

variable "blocked_country_codes" {
  description = "ISO 3166-1 alpha-2 country codes to block outright. Empty disables geo blocking."
  type        = list(string)
  default     = []
}

variable "allowed_ip_addresses" {
  description = "CIDRs that bypass all subsequent rules, e.g. monitoring or office egress."
  type        = list(string)
  default     = []
}

variable "blocked_ip_addresses" {
  description = "CIDRs blocked before any other rule is evaluated."
  type        = list(string)
  default     = []
}

variable "enable_logging" {
  description = "Send WAF logs to CloudWatch Logs."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention for the WAF log group."
  type        = number
  default     = 90
}

variable "kms_key_arn" {
  description = "KMS key ARN encrypting the WAF log group."
  type        = string
  default     = null
}

variable "redact_authorization_header" {
  description = "Redact the Authorization header from WAF logs."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}
