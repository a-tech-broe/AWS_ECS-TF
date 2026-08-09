###############################################################################
# Identity
###############################################################################

variable "name" {
  description = "Service name. Used for the task family, log group, target group and IAM roles."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{0,23}$", var.name))
    error_message = "name must be alphanumeric with hyphens and at most 24 characters, so derived target group names stay within the 32-character limit."
  }
}

variable "cluster_arn" {
  description = "ARN of the ECS cluster."
  type        = string
}

variable "cluster_name" {
  description = "Name of the ECS cluster, used for metric dimensions and the log group path."
  type        = string
}

variable "vpc_id" {
  description = "VPC hosting the service."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets the tasks run in. Use every AZ the cluster spans."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "Give the service at least two subnets so a single AZ failure cannot take it down."
  }
}

###############################################################################
# Container
###############################################################################

variable "image" {
  description = "Full container image reference. Pin by digest or immutable tag, never ':latest'."
  type        = string
}

variable "container_port" {
  description = "Port the container listens on. Null for workers with no inbound traffic."
  type        = number
  default     = 8080
}

variable "cpu" {
  description = "Task CPU units. Must be a valid Fargate value (256, 512, 1024, 2048, 4096, 8192, 16384)."
  type        = number
  default     = 512

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096, 8192, 16384], var.cpu)
    error_message = "cpu must be one of 256, 512, 1024, 2048, 4096, 8192, 16384."
  }
}

variable "memory" {
  description = "Task memory in MiB. Must pair legally with the chosen CPU value."
  type        = number
  default     = 1024
}

variable "cpu_architecture" {
  description = "X86_64 or ARM64. ARM64 (Graviton) is materially cheaper when the image supports it."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "command" {
  description = "Override the image CMD."
  type        = list(string)
  default     = null
}

variable "entrypoint" {
  description = "Override the image ENTRYPOINT."
  type        = list(string)
  default     = null
}

variable "environment" {
  description = "Plain environment variables. Never put credentials here; use `secrets`."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Secret environment variables as name => Secrets Manager or SSM Parameter ARN. Injected at task start, never stored in the task definition."
  type        = map(string)
  default     = {}
}

variable "readonly_root_filesystem" {
  description = "Mount the container root filesystem read-only. Turn off only for images that cannot be made to write elsewhere."
  type        = bool
  default     = true
}

variable "container_user" {
  description = "User the container runs as. Defaults to a non-root UID."
  type        = string
  default     = "1000:1000"
}

variable "writable_volumes" {
  description = "Ephemeral scratch volumes mounted read-write, needed when the root filesystem is read-only. Map of volume name => container mount path."
  type        = map(string)
  default     = {}
}

variable "container_health_check" {
  description = "Container-level health check. This is what makes the ECS circuit breaker able to detect a broken image."
  type = object({
    command      = list(string)
    interval     = optional(number, 30)
    timeout      = optional(number, 5)
    retries      = optional(number, 3)
    start_period = optional(number, 30)
  })
  default = null
}

variable "stop_timeout" {
  description = "Seconds ECS waits for the container to exit after SIGTERM before killing it. Must exceed your longest in-flight request."
  type        = number
  default     = 30
}

variable "additional_container_definitions" {
  description = "Extra container definitions (sidecars) merged into the task definition verbatim."
  type        = any
  default     = []
}

variable "enable_nonessential_sidecar_failure_tolerance" {
  description = "Mark sidecars non-essential so their failure does not restart the task. Only meaningful when sidecars are supplied without an explicit `essential` key."
  type        = bool
  default     = true
}

###############################################################################
# Load balancing
###############################################################################

variable "enable_load_balancer" {
  description = "Register the service behind the ALB. False for queue workers and cron-style services."
  type        = bool
  default     = true
}

variable "listener_arn" {
  description = "HTTPS listener ARN the routing rule attaches to. Required when the load balancer is enabled."
  type        = string
  default     = null
}

variable "alb_security_group_id" {
  description = "Security group of the ALB, allowed as the only ingress source to the tasks."
  type        = string
  default     = null
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix, required for request-count-based autoscaling and ALB alarms."
  type        = string
  default     = null
}

variable "listener_rule_priority" {
  description = "Priority of the listener rule. Must be unique across all services on the listener."
  type        = number
  default     = 100
}

variable "host_headers" {
  description = "Host headers routed to this service."
  type        = list(string)
  default     = []
}

variable "path_patterns" {
  description = "Path patterns routed to this service, e.g. ['/api/*']."
  type        = list(string)
  default     = []
}

variable "health_check" {
  description = "Target group health check. `healthy_threshold` x `interval` is how long a new task waits before receiving traffic."
  type = object({
    path                = optional(string, "/healthz")
    matcher             = optional(string, "200")
    interval            = optional(number, 15)
    timeout             = optional(number, 5)
    healthy_threshold   = optional(number, 2)
    unhealthy_threshold = optional(number, 3)
  })
  default = {}
}

variable "deregistration_delay" {
  description = "Seconds the ALB drains a target before deregistering. Must exceed your longest request."
  type        = number
  default     = 30
}

variable "target_group_protocol_version" {
  description = "Backend protocol version: HTTP1, HTTP2, or GRPC."
  type        = string
  default     = "HTTP1"

  validation {
    condition     = contains(["HTTP1", "HTTP2", "GRPC"], var.target_group_protocol_version)
    error_message = "target_group_protocol_version must be HTTP1, HTTP2, or GRPC."
  }
}

variable "stickiness" {
  description = "Session stickiness on the target group. Avoid unless the app genuinely holds server-side session state."
  type = object({
    enabled         = bool
    duration        = optional(number, 86400)
    cookie_name     = optional(string, null)
    stickiness_type = optional(string, "lb_cookie")
  })
  default = null
}

variable "health_check_grace_period_seconds" {
  description = "How long ECS ignores failing health checks after a task starts. Set this above your cold-start time."
  type        = number
  default     = 60
}

###############################################################################
# Deployment
###############################################################################

variable "desired_count" {
  description = "Initial task count. Autoscaling owns this value after the first apply."
  type        = number
  default     = 2

  validation {
    condition     = var.desired_count >= 1
    error_message = "desired_count must be at least 1."
  }
}

variable "deployment_minimum_healthy_percent" {
  description = "Percentage of desired tasks that must stay healthy during a deploy."
  type        = number
  default     = 100
}

variable "deployment_maximum_percent" {
  description = "Ceiling on running tasks during a deploy. 200 with a 100 minimum gives a full blue/green style rollout."
  type        = number
  default     = 200
}

variable "enable_deployment_circuit_breaker" {
  description = "Abort and roll back a deployment that cannot reach steady state. This is the single most valuable safety net for ECS deploys."
  type        = bool
  default     = true
}

variable "wait_for_steady_state" {
  description = "Block terraform apply until the deployment stabilises, so a failed rollout fails the pipeline."
  type        = bool
  default     = true
}

variable "capacity_provider_strategy" {
  description = "Per-service Fargate/Fargate Spot split. Empty uses the cluster default."
  type = list(object({
    capacity_provider = string
    weight            = number
    base              = optional(number, 0)
  }))
  default = []
}

variable "availability_zone_rebalancing" {
  description = "Let ECS redistribute tasks when AZ capacity becomes unbalanced."
  type        = string
  default     = "ENABLED"

  validation {
    condition     = contains(["ENABLED", "DISABLED"], var.availability_zone_rebalancing)
    error_message = "availability_zone_rebalancing must be ENABLED or DISABLED."
  }
}

variable "enable_execute_command" {
  description = "Allow ECS Exec into tasks. Sessions are encrypted and audited at the cluster level."
  type        = bool
  default     = true
}

variable "enable_service_connect" {
  description = "Register the service in the cluster's Service Connect namespace for service-to-service discovery."
  type        = bool
  default     = false
}

variable "service_connect_port_name" {
  description = "Port mapping name advertised through Service Connect. Defaults to the service name."
  type        = string
  default     = null
}

variable "propagate_tags" {
  description = "Propagate tags to tasks from SERVICE or TASK_DEFINITION."
  type        = string
  default     = "SERVICE"
}

###############################################################################
# Autoscaling
###############################################################################

variable "enable_autoscaling" {
  description = "Attach Application Auto Scaling to the service."
  type        = bool
  default     = true
}

variable "min_capacity" {
  description = "Minimum task count. Keep at 2 or more in production so a single task failure is never a full outage."
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Maximum task count."
  type        = number
  default     = 10
}

variable "cpu_target_value" {
  description = "Target average CPU utilisation percentage. Null disables CPU-based scaling."
  type        = number
  default     = 65
}

variable "memory_target_value" {
  description = "Target average memory utilisation percentage. Null disables memory-based scaling."
  type        = number
  default     = 75
}

variable "request_count_target_value" {
  description = "Target ALB requests per task. Null disables request-based scaling, which is usually the most responsive signal for web services."
  type        = number
  default     = null
}

variable "scale_in_cooldown" {
  description = "Seconds before another scale-in. Longer than scale-out on purpose, to avoid flapping."
  type        = number
  default     = 300
}

variable "scale_out_cooldown" {
  description = "Seconds before another scale-out."
  type        = number
  default     = 60
}

variable "scheduled_scaling" {
  description = "Scheduled capacity changes, e.g. scaling down overnight."
  type = list(object({
    name         = string
    schedule     = string
    min_capacity = number
    max_capacity = number
    timezone     = optional(string, "UTC")
  }))
  default = []
}

###############################################################################
# IAM, logging, observability
###############################################################################

variable "task_role_policy_json" {
  description = "IAM policy JSON granting the application access to AWS resources. Null creates a task role with no permissions beyond ECS Exec."
  type        = string
  default     = null
}

variable "execution_role_extra_policy_json" {
  description = "Extra IAM policy JSON for the execution role, e.g. cross-account ECR pulls."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Retention for the service log group."
  type        = number
  default     = 30
}

variable "kms_key_arn" {
  description = "KMS key ARN encrypting the log group and permitted for secret decryption."
  type        = string
  default     = null
}

variable "enable_alarms" {
  description = "Create CloudWatch alarms for this service."
  type        = bool
  default     = true
}

variable "alarm_actions" {
  description = "SNS topic ARNs notified when an alarm fires."
  type        = list(string)
  default     = []
}

variable "alarm_thresholds" {
  description = "Thresholds for the per-service alarms."
  type = object({
    cpu_utilization       = optional(number, 85)
    memory_utilization    = optional(number, 85)
    target_5xx_count      = optional(number, 10)
    target_response_time  = optional(number, 2)
    min_running_tasks     = optional(number, 1)
    unhealthy_host_count  = optional(number, 0)
    evaluation_periods    = optional(number, 2)
    datapoints_to_alarm   = optional(number, 2)
    period_seconds        = optional(number, 60)
    response_time_periods = optional(number, 5)
  })
  default = {}
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}
