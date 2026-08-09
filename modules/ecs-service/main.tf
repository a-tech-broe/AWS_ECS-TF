###############################################################################
# Task definition and service.
#
# Defaults are the safe ones: non-root user, read-only root filesystem, tasks in
# private subnets reachable only from the ALB security group, and a deployment
# circuit breaker that rolls back a release that never reaches steady state.
###############################################################################

locals {
  port_name = coalesce(var.service_connect_port_name, var.name)

  port_mappings = var.container_port == null ? [] : [
    {
      name          = local.port_name
      containerPort = var.container_port
      hostPort      = var.container_port
      protocol      = "tcp"
      appProtocol   = var.target_group_protocol_version == "GRPC" ? "grpc" : "http"
    },
  ]

  mount_points = [
    for volume_name, mount_path in var.writable_volumes : {
      sourceVolume  = volume_name
      containerPath = mount_path
      readOnly      = false
    }
  ]

  log_configuration = {
    logDriver = "awslogs"
    options = {
      "awslogs-group"                = aws_cloudwatch_log_group.this.name
      "awslogs-region"               = local.region
      "awslogs-stream-prefix"        = "ecs"
      "mode"                         = "non-blocking"
      "max-buffer-size"              = "4m"
      "awslogs-multiline-pattern"    = "^\\[?\\d{4}-\\d{2}-\\d{2}"
      "awslogs-datetime-format-hint" = ""
    }
  }

  primary_container = merge(
    {
      name                   = var.name
      image                  = var.image
      essential              = true
      cpu                    = 0
      portMappings           = local.port_mappings
      mountPoints            = local.mount_points
      readonlyRootFilesystem = var.readonly_root_filesystem
      stopTimeout            = var.stop_timeout
      environment            = [for k in sort(keys(var.environment)) : { name = k, value = var.environment[k] }]
      secrets                = [for k in sort(keys(var.secrets)) : { name = k, valueFrom = var.secrets[k] }]

      logConfiguration = {
        logDriver = local.log_configuration.logDriver
        options = {
          for k, v in local.log_configuration.options : k => v if v != ""
        }
      }

      # Required for ECS Exec to reap zombie processes cleanly.
      linuxParameters = {
        initProcessEnabled = var.enable_execute_command
      }

      ulimits = [
        {
          name      = "nofile"
          softLimit = 65536
          hardLimit = 65536
        },
      ]
    },
    var.container_user != null && var.container_user != "" ? { user = var.container_user } : {},
    var.command != null ? { command = var.command } : {},
    var.entrypoint != null ? { entryPoint = var.entrypoint } : {},
    var.container_health_check != null ? {
      healthCheck = {
        command     = var.container_health_check.command
        interval    = var.container_health_check.interval
        timeout     = var.container_health_check.timeout
        retries     = var.container_health_check.retries
        startPeriod = var.container_health_check.start_period
      }
    } : {},
  )

  sidecars = [
    for c in var.additional_container_definitions :
    merge(
      {
        essential = !var.enable_nonessential_sidecar_failure_tolerance
        logConfiguration = {
          logDriver = "awslogs"
          options = {
            "awslogs-group"         = aws_cloudwatch_log_group.this.name
            "awslogs-region"        = local.region
            "awslogs-stream-prefix" = "ecs"
            "mode"                  = "non-blocking"
          }
        }
      },
      c,
    )
  ]

  container_definitions = concat([local.primary_container], local.sidecars)
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.cluster_name}/${var.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, { Name = "${var.name}-logs" })
}

# --- Networking ---------------------------------------------------------------

resource "aws_security_group" "this" {
  name        = "${var.name}-ecs-tasks"
  description = "Task security group for the ${var.name} service"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-ecs-tasks" })

  lifecycle {
    create_before_destroy = true
  }
}

# The only inbound path is from the load balancer. Referencing the ALB's
# security group rather than a CIDR keeps this correct if subnets ever change.
resource "aws_vpc_security_group_ingress_rule" "from_alb" {
  count = var.enable_load_balancer && var.container_port != null ? 1 : 0

  security_group_id            = aws_security_group.this.id
  description                  = "Application traffic from the load balancer"
  referenced_security_group_id = var.alb_security_group_id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

# Service Connect sidecars talk to each other inside the VPC on the app port.
resource "aws_vpc_security_group_ingress_rule" "from_self" {
  count = var.enable_service_connect && var.container_port != null ? 1 : 0

  security_group_id            = aws_security_group.this.id
  description                  = "Service Connect traffic from peer tasks"
  referenced_security_group_id = aws_security_group.this.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

# Egress stays open: Fargate needs it for image pulls, secrets, logs and
# outbound API calls. Control outbound exposure at the NAT/endpoint layer.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- Task definition ----------------------------------------------------------

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions    = jsonencode(local.container_definitions)

  runtime_platform {
    cpu_architecture        = var.cpu_architecture
    operating_system_family = "LINUX"
  }

  dynamic "volume" {
    for_each = var.writable_volumes

    content {
      name = volume.key
    }
  }

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    create_before_destroy = true
  }
}

# --- Service ------------------------------------------------------------------

resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count

  enable_execute_command  = var.enable_execute_command
  enable_ecs_managed_tags = true
  propagate_tags          = var.propagate_tags

  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent
  availability_zone_rebalancing      = var.availability_zone_rebalancing
  wait_for_steady_state              = var.wait_for_steady_state

  health_check_grace_period_seconds = var.enable_load_balancer ? var.health_check_grace_period_seconds : null

  deployment_controller {
    type = "ECS"
  }

  deployment_circuit_breaker {
    enable   = var.enable_deployment_circuit_breaker
    rollback = var.enable_deployment_circuit_breaker
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.this.id]
    assign_public_ip = false
  }

  dynamic "capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy

    content {
      capacity_provider = capacity_provider_strategy.value.capacity_provider
      weight            = capacity_provider_strategy.value.weight
      base              = capacity_provider_strategy.value.base
    }
  }

  dynamic "load_balancer" {
    for_each = var.enable_load_balancer ? [1] : []

    content {
      target_group_arn = aws_lb_target_group.this[0].arn
      container_name   = var.name
      container_port   = var.container_port
    }
  }

  dynamic "service_connect_configuration" {
    for_each = var.enable_service_connect ? [1] : []

    content {
      enabled = true

      log_configuration {
        log_driver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "service-connect"
        }
      }

      dynamic "service" {
        for_each = var.container_port != null ? [1] : []

        content {
          port_name      = local.port_name
          discovery_name = var.name

          client_alias {
            port     = var.container_port
            dns_name = var.name
          }
        }
      }
    }
  }

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    # Autoscaling owns desired_count after creation; without this every plan
    # would try to reset the service to its initial size.
    ignore_changes = [desired_count]

    precondition {
      condition     = !var.enable_load_balancer || (var.listener_arn != null && var.alb_security_group_id != null && var.container_port != null)
      error_message = "enable_load_balancer requires listener_arn, alb_security_group_id, and container_port."
    }

    precondition {
      condition     = !var.enable_load_balancer || length(var.host_headers) > 0 || length(var.path_patterns) > 0
      error_message = "A load-balanced service needs at least one host_header or path_pattern, otherwise its listener rule can never match."
    }

    precondition {
      condition     = !var.enable_autoscaling || var.min_capacity <= var.max_capacity
      error_message = "min_capacity must not exceed max_capacity."
    }

    precondition {
      condition     = !var.enable_load_balancer || var.alb_arn_suffix != null
      error_message = "A load-balanced service needs alb_arn_suffix for its ALB alarms and request-count scaling policy."
    }
  }

  depends_on = [
    aws_lb_listener_rule.this,
    aws_iam_role_policy.execution,
  ]
}
