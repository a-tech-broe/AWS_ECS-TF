variable "name" {
  description = "Name prefix for the IAM roles."
  type        = string
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false when another stack in this account already created it, since it is a per-account singleton."
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
