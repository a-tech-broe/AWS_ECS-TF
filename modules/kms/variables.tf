variable "alias" {
  description = "Alias name for the key, without the 'alias/' prefix."
  type        = string
}

variable "description" {
  description = "Human-readable purpose of the key."
  type        = string
}

variable "deletion_window_in_days" {
  description = "Waiting period before a scheduled key deletion completes."
  type        = number
  default     = 30

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days must be between 7 and 30."
  }
}

variable "multi_region" {
  description = "Create a multi-region key (needed only for cross-region replication)."
  type        = bool
  default     = false
}

variable "service_principals" {
  description = "AWS service principals granted cryptographic use of the key, e.g. ['sns.amazonaws.com']."
  type        = list(string)
  default     = []
}

variable "enable_source_account_condition" {
  description = "Scope the service-principal grant with aws:SourceAccount. Set false when a caller such as CloudWatch publishing to an encrypted SNS topic makes the call without that context key, which would otherwise deny it."
  type        = bool
  default     = true
}

variable "enable_cloudwatch_logs" {
  description = "Grant the regional CloudWatch Logs principal use of the key, scoped by log-group encryption context."
  type        = bool
  default     = false
}

variable "grant_creator_service_principals" {
  description = "Service principals allowed to create grants for AWS resources (e.g. ['ecs.amazonaws.com'])."
  type        = list(string)
  default     = []
}

variable "key_administrator_arns" {
  description = "IAM principal ARNs allowed to administer (but not use) the key."
  type        = list(string)
  default     = []
}

variable "key_user_arns" {
  description = "IAM principal ARNs allowed cryptographic use of the key."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to the key."
  type        = map(string)
  default     = {}
}
