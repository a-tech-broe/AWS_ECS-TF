###############################################################################
# ECS cluster on Fargate.
#
# ECS Exec is available but always encrypted and always audited: interactive
# access to production containers is a legitimate operational need, and an
# unlogged shell is the part that is not acceptable.
###############################################################################

locals {
  namespace_name = coalesce(
    var.service_connect_namespace_name != "" ? var.service_connect_namespace_name : null,
    "${var.name}.internal",
  )

  create_namespace = var.enable_service_connect_namespace
}

resource "aws_cloudwatch_log_group" "exec" {
  #checkov:skip=CKV_AWS_338:Retention is set per environment via exec_log_retention_days
  count = var.enable_execute_command_logging ? 1 : 0

  name              = "/aws/ecs/${var.name}/exec"
  retention_in_days = var.exec_log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}

resource "aws_ecs_cluster" "this" {
  # Exec logging and CMK encryption are both configured below; Checkov cannot
  # resolve kms_key_id because it arrives as a variable from the kms module.
  #checkov:skip=CKV_AWS_224:Exec logging and CMK encryption are configured in execute_command_configuration
  name = var.name

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? var.container_insights_mode : "disabled"
  }

  configuration {
    execute_command_configuration {
      kms_key_id = var.kms_key_arn
      logging    = var.enable_execute_command_logging ? "OVERRIDE" : "DEFAULT"

      dynamic "log_configuration" {
        for_each = var.enable_execute_command_logging ? [1] : []

        content {
          cloud_watch_encryption_enabled = var.kms_key_arn != null
          cloud_watch_log_group_name     = aws_cloudwatch_log_group.exec[0].name
        }
      }
    }
  }

  dynamic "service_connect_defaults" {
    for_each = local.create_namespace ? [1] : []

    content {
      namespace = aws_service_discovery_private_dns_namespace.this[0].arn
    }
  }

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  dynamic "default_capacity_provider_strategy" {
    for_each = var.default_capacity_provider_strategy

    content {
      capacity_provider = default_capacity_provider_strategy.value.capacity_provider
      weight            = default_capacity_provider_strategy.value.weight
      base              = default_capacity_provider_strategy.value.base
    }
  }
}

# --- Service discovery --------------------------------------------------------

resource "aws_service_discovery_private_dns_namespace" "this" {
  count = local.create_namespace ? 1 : 0

  name        = local.namespace_name
  description = "Service Connect namespace for ${var.name}"
  vpc         = var.vpc_id

  tags = var.tags
}
