variable "name" {
  description = "Cluster name."
  type        = string
}

variable "enable_container_insights" {
  description = "Enable CloudWatch Container Insights for cluster-level metrics."
  type        = bool
  default     = true
}

variable "container_insights_mode" {
  description = "Container Insights level: 'enhanced' adds per-task metrics at higher cost, 'enabled' is the standard tier."
  type        = string
  default     = "enabled"

  validation {
    condition     = contains(["enabled", "enhanced"], var.container_insights_mode)
    error_message = "container_insights_mode must be 'enabled' or 'enhanced'."
  }
}

variable "kms_key_arn" {
  description = "KMS key ARN used for ECS Exec session encryption and the exec audit log group."
  type        = string
  default     = null
}

variable "enable_execute_command_logging" {
  description = "Audit every ECS Exec session to CloudWatch Logs. Required to make interactive access accountable."
  type        = bool
  default     = true
}

variable "exec_log_retention_days" {
  description = "Retention for the ECS Exec audit log group."
  type        = number
  default     = 365
}

variable "default_capacity_provider_strategy" {
  description = "Default split between FARGATE and FARGATE_SPOT for services that do not override it."
  type = list(object({
    capacity_provider = string
    weight            = number
    base              = optional(number, 0)
  }))

  default = [
    {
      capacity_provider = "FARGATE"
      weight            = 1
      base              = 1
    },
  ]

  validation {
    condition = alltrue([
      for s in var.default_capacity_provider_strategy :
      contains(["FARGATE", "FARGATE_SPOT"], s.capacity_provider)
    ])
    error_message = "Only FARGATE and FARGATE_SPOT are valid capacity providers for this platform."
  }
}

variable "enable_service_connect_namespace" {
  description = "Create a Cloud Map namespace and set it as the cluster's default for ECS Service Connect."
  type        = bool
  default     = true
}

variable "service_connect_namespace_name" {
  description = "DNS namespace for service-to-service discovery. Defaults to '<cluster>.internal'."
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC the Service Connect private DNS namespace is associated with. Required when the namespace is enabled."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}
