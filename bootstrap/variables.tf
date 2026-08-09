variable "aws_region" {
  description = "Region that hosts the Terraform state bucket and lock table."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project slug used to name created resources."
  type        = string
  default     = "ecs-platform"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.project))
    error_message = "project must be lowercase alphanumeric with hyphens, 3-32 characters."
  }
}

variable "create_state_bucket" {
  description = <<-EOT
    Create the state bucket and its KMS key. Set false when the account already
    has a state bucket you intend to reuse — creating one that exists fails the
    apply, and a pre-existing bucket may be shared with other projects whose
    settings this root should not take over.
  EOT
  type        = bool
  default     = true
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

variable "create_lock_table" {
  description = "Create the DynamoDB state lock table. Set false to reuse an existing one."
  type        = bool
  default     = true
}

variable "lock_table_name" {
  description = "Name of the DynamoDB lock table. Leave empty to derive '<project>-tflock'."
  type        = string
  default     = ""
}

variable "trusted_principal_arns" {
  description = "Optional IAM principal ARNs allowed to read/write state. Empty means account-level IAM governs access."
  type        = list(string)
  default     = []
}
