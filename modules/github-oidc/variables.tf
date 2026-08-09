variable "name" {
  description = "Name prefix for the IAM roles."
  type        = string
}

variable "create_oidc_provider" {
  description = <<-EOT
    Create the GitHub OIDC provider. It is a per-account singleton, so set false
    when the account already has one and this module will reference it by its
    deterministic ARN instead.

    Creating it requires IAM permissions that the CI apply role deliberately
    does not hold — an identity provider is a trust anchor, and letting the
    pipeline mint one would let it grant itself access from anywhere. Leave this
    false in CI and create the provider once as an administrator.
  EOT
  type        = bool
  default     = true
}

variable "github_subjects" {
  description = "OIDC subject claims allowed to assume the roles, e.g. ['repo:acme/infra:ref:refs/heads/main']. Never use a bare wildcard: any repo could then assume the role."
  type        = list(string)

  validation {
    condition = alltrue([
      for s in var.github_subjects : startswith(s, "repo:") && !startswith(s, "repo:*")
    ])
    error_message = "Each subject must start with 'repo:' and name a specific repository."
  }
}

variable "plan_policy_arns" {
  description = "Managed policy ARNs attached to the read-only plan role."
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
}

variable "apply_policy_arns" {
  description = "Managed policy ARNs attached to the apply role. Scope this down from PowerUserAccess once the resource set is stable."
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/PowerUserAccess"]
}

variable "apply_inline_policy_json" {
  description = "Extra inline policy for the apply role, typically the IAM permissions Terraform needs to manage task roles."
  type        = string
  default     = null
}

variable "state_bucket_arn" {
  description = "State bucket ARN both roles need access to. Null skips the state policy."
  type        = string
  default     = null
}

variable "state_lock_table_arn" {
  description = "ARN of the DynamoDB state lock table. Without this a role can read and write state but cannot take the lock, so every plan and apply fails at the very first step."
  type        = string
  default     = null
}

variable "state_kms_key_arn" {
  description = "KMS key ARN encrypting state objects."
  type        = string
  default     = null
}

variable "max_session_duration" {
  description = "Maximum session duration in seconds for the CI roles."
  type        = number
  default     = 3600
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}
