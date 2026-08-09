variable "aws_region" {
  description = "Region that hosts the Terraform state bucket."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project slug used to name the state bucket and KMS alias."
  type        = string
  default     = "ecs-platform"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.project))
    error_message = "project must be lowercase alphanumeric with hyphens, 3-32 characters."
  }
}

variable "state_bucket_name" {
  description = "Explicit state bucket name. Leave empty to derive '<project>-tfstate-<account-id>'."
  type        = string
  default     = ""
}

variable "noncurrent_version_retention_days" {
  description = "How long superseded state versions are retained before expiry."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_retention_days >= 30
    error_message = "Retain superseded state for at least 30 days so rollbacks stay possible."
  }
}

variable "trusted_principal_arns" {
  description = "Optional IAM principal ARNs allowed to read/write state. Empty means account-level IAM governs access."
  type        = list(string)
  default     = []
}
