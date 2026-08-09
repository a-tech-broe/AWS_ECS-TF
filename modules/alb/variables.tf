variable "name" {
  description = "Load balancer name. Must be 32 characters or fewer."
  type        = string

  validation {
    condition     = length(var.name) <= 32
    error_message = "ALB names are limited to 32 characters."
  }
}

variable "vpc_id" {
  description = "VPC hosting the load balancer."
  type        = string
}

variable "vpc_cidr_block" {
  description = "CIDR of the VPC. The load balancer's egress is confined to this range, since all of its targets are inside the VPC."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr_block, 0))
    error_message = "vpc_cidr_block must be a valid CIDR."
  }
}

variable "subnet_ids" {
  description = "Subnets for the load balancer. Public subnets for an internet-facing ALB, private for an internal one."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "An ALB needs subnets in at least two Availability Zones."
  }
}

variable "internal" {
  description = "Create an internal (VPC-only) load balancer."
  type        = bool
  default     = false
}

variable "certificate_arn" {
  description = "ACM certificate ARN for the HTTPS listener."
  type        = string
}

variable "additional_certificate_arns" {
  description = "Extra ACM certificates attached to the HTTPS listener for SNI."
  type        = list(string)
  default     = []
}

variable "ssl_policy" {
  description = "ELB security policy. The default negotiates TLS 1.3 and 1.2 only."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "ingress_cidr_blocks" {
  description = "CIDRs allowed to reach the listeners. Narrow this for internal or restricted load balancers."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "idle_timeout" {
  description = "Seconds an idle connection is kept open. Raise for long-polling or streaming workloads."
  type        = number
  default     = 60
}

variable "enable_deletion_protection" {
  description = "Block accidental deletion of the load balancer. Keep true in production."
  type        = bool
  default     = true
}

variable "enable_http2" {
  description = "Enable HTTP/2 on the load balancer."
  type        = bool
  default     = true
}

variable "enable_cross_zone_load_balancing" {
  description = "Spread traffic evenly across AZs regardless of target distribution."
  type        = bool
  default     = true
}

variable "enable_access_logs" {
  description = "Write ALB access and connection logs to a dedicated S3 bucket created by this module."
  type        = bool
  default     = true
}

variable "access_logs_retention_days" {
  description = "Days before access log objects expire."
  type        = number
  default     = 90
}

variable "access_logs_transition_days" {
  description = "Days before access logs move to STANDARD_IA. The transition is skipped entirely when it would land on or after the expiry day, which S3 rejects."
  type        = number
  default     = 30
}

variable "access_logs_bucket_force_destroy" {
  description = "Allow Terraform to delete the log bucket while it still holds objects. Keep false in production."
  type        = bool
  default     = false
}

variable "default_response_body" {
  description = "Body returned by the HTTPS listener default action when no service rule matches."
  type        = string
  default     = "Not Found"
}

variable "drop_invalid_header_fields" {
  description = "Drop malformed HTTP headers before they reach targets. Mitigates request smuggling."
  type        = bool
  default     = true
}

variable "desync_mitigation_mode" {
  description = "How the ALB handles desync-prone requests: monitor, defensive, or strictest."
  type        = string
  default     = "strictest"

  validation {
    condition     = contains(["monitor", "defensive", "strictest"], var.desync_mitigation_mode)
    error_message = "desync_mitigation_mode must be monitor, defensive, or strictest."
  }
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}
