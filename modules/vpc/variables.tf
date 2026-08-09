variable "name" {
  description = "Name prefix for all VPC resources."
  type        = string
}

variable "cidr_block" {
  description = "IPv4 CIDR for the VPC. A /16 gives each AZ a /20 of private space."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr_block, 0)) && tonumber(split("/", var.cidr_block)[1]) <= 20
    error_message = "cidr_block must be a valid CIDR of /20 or larger."
  }
}

variable "az_count" {
  description = "Number of Availability Zones to span. Three is the fault-tolerance baseline."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

variable "single_nat_gateway" {
  description = "Share one NAT Gateway across all AZs. Saves cost in dev; a per-AZ NAT is required for AZ-fault tolerance in prod."
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "Send VPC Flow Logs to CloudWatch Logs."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Retention for the flow log group."
  type        = number
  default     = 90
}

variable "flow_log_traffic_type" {
  description = "Which traffic to capture: ACCEPT, REJECT, or ALL."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.flow_log_traffic_type)
    error_message = "flow_log_traffic_type must be ACCEPT, REJECT, or ALL."
  }
}

variable "kms_key_arn" {
  description = "KMS key ARN used to encrypt the flow log group."
  type        = string
  default     = null
}

variable "enable_vpc_endpoints" {
  description = "Create the interface/gateway endpoints ECS tasks need so image pulls, logs and secrets never traverse NAT."
  type        = bool
  default     = true
}

variable "interface_endpoint_services" {
  description = "Interface endpoint service short names to create when endpoints are enabled."
  type        = list(string)
  default = [
    "ecr.api",
    "ecr.dkr",
    "logs",
    "secretsmanager",
    "ssm",
    "ssmmessages",
    "kms",
    "sts",
  ]
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}
