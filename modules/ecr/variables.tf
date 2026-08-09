variable "repositories" {
  description = "Repository names to create, typically one per deployable application."
  type        = list(string)

  validation {
    condition     = alltrue([for r in var.repositories : can(regex("^[a-z0-9][a-z0-9._/-]{1,255}$", r))])
    error_message = "Repository names must be lowercase and may contain . _ / and -."
  }
}

variable "name_prefix" {
  description = "Prefix applied to every repository name, e.g. 'acme' yields 'acme/api'."
  type        = string
  default     = ""
}

variable "image_tag_mutability" {
  description = "IMMUTABLE prevents a tag from being repointed after deploy, which is what makes a rollback deterministic."
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be MUTABLE or IMMUTABLE."
  }
}

variable "kms_key_arn" {
  description = "KMS key ARN for image encryption at rest. Null falls back to AES256."
  type        = string
  default     = null
}

variable "enable_enhanced_scanning" {
  description = "Enable registry-level ENHANCED scanning (Inspector, continuous). False uses per-repository BASIC scan-on-push."
  type        = bool
  default     = true
}

variable "manage_registry_scanning" {
  description = "Manage the account-wide registry scanning configuration here. Set false when another stack owns it, since the setting is per-account not per-repository."
  type        = bool
  default     = false
}

variable "untagged_image_expiry_days" {
  description = "Days before untagged images are removed."
  type        = number
  default     = 7
}

variable "tagged_image_retention_count" {
  description = "How many images to keep per release-tag prefix."
  type        = number
  default     = 50
}

variable "release_tag_prefixes" {
  description = "Tag prefixes considered releases and kept under the retention count."
  type        = list(string)
  default     = ["v", "release", "main", "prod"]
}

variable "pull_principal_arns" {
  description = "IAM principal ARNs granted pull access via repository policy, e.g. ECS execution roles in other accounts."
  type        = list(string)
  default     = []
}

variable "push_principal_arns" {
  description = "IAM principal ARNs granted push access via repository policy, e.g. the CI deploy role."
  type        = list(string)
  default     = []
}

variable "force_delete" {
  description = "Allow Terraform to delete repositories that still contain images. Keep false in production."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to all repositories."
  type        = map(string)
  default     = {}
}
