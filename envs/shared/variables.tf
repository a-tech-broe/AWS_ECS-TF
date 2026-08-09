variable "aws_region" {
  description = "Region for shared resources."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project slug used as a name prefix."
  type        = string
  default     = "ecs-platform"
}

variable "repository" {
  description = "Source repository, recorded as a tag on every resource."
  type        = string
  default     = "AWS_ECS-TF"
}

variable "ecr_repositories" {
  description = "Application repositories to create. One per deployable service."
  type        = list(string)
  default     = []
}

variable "ecr_name_prefix" {
  description = "Namespace prefix for repositories, e.g. 'ecs-platform' yields 'ecs-platform/api'."
  type        = string
  default     = ""
}

variable "enable_enhanced_scanning" {
  description = "Use Inspector-backed continuous scanning instead of basic scan-on-push."
  type        = bool
  default     = true
}

variable "manage_registry_scanning" {
  description = "Let this root own the account-wide ECR scanning configuration."
  type        = bool
  default     = true
}

variable "ecr_force_delete" {
  description = "Allow deletion of repositories that still hold images."
  type        = bool
  default     = false
}

variable "create_github_oidc" {
  description = "Create the GitHub Actions OIDC provider and CI roles."
  type        = bool
  default     = true
}

variable "create_oidc_provider" {
  description = "Create the OIDC provider itself. Set false if the account already has one."
  type        = bool
  default     = true
}

variable "github_subjects" {
  description = "OIDC subjects allowed to assume the apply role, e.g. ['repo:owner/AWS_ECS-TF:ref:refs/heads/main']."
  type        = list(string)
  default     = []
}

variable "state_bucket_arn" {
  description = "ARN of the Terraform state bucket, granted to the CI roles."
  type        = string
  default     = null
}

variable "state_kms_key_arn" {
  description = "ARN of the KMS key encrypting Terraform state."
  type        = string
  default     = null
}

variable "tags" {
  description = "Additional tags applied to shared resources."
  type        = map(string)
  default     = {}
}
