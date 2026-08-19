###############################################################################
# Target group and listener rule.
#
# The target group uses create_before_destroy so a change that forces
# replacement (protocol version, health check port) rolls forward rather than
# briefly leaving the listener pointing at nothing.
###############################################################################

locals {
  # create_before_destroy cannot build the replacement while a target group of
  # the same name still exists, so the name has to change whenever one of the
  # replace-forcing attributes does. `name_prefix` would do this too, but AWS
  # caps it at six characters, which is not enough to tell two services apart.
  # `name` is validated to 24 characters, so this stays inside the 32-character
  # target group limit.
  target_group_name = "${var.name}-${substr(sha256(jsonencode([
    var.container_port,
    var.target_group_protocol_version,
    var.vpc_id,
  ])), 0, 6)}"
}

resource "aws_lb_target_group" "this" {
  # TLS terminates at the ALB; the hop to the task is plain HTTP inside a
  # private subnet, reachable only from the load balancer's security group.
  #checkov:skip=CKV_AWS_378:TLS terminates at the ALB, backend hop is inside the VPC
  count = var.enable_load_balancer ? 1 : 0

  name        = local.target_group_name
  vpc_id      = var.vpc_id
  port        = var.container_port
  protocol    = "HTTP"
  target_type = "ip"

  protocol_version     = var.target_group_protocol_version
  deregistration_delay = var.deregistration_delay

  # Sends each request to the target with the fewest in-flight requests, which
  # handles heterogeneous request costs far better than round robin.
  load_balancing_algorithm_type = "least_outstanding_requests"

  health_check {
    enabled             = true
    path                = var.health_check.path
    matcher             = var.health_check.matcher
    interval            = var.health_check.interval
    timeout             = var.health_check.timeout
    healthy_threshold   = var.health_check.healthy_threshold
    unhealthy_threshold = var.health_check.unhealthy_threshold
    protocol            = "HTTP"
    port                = "traffic-port"
  }

  dynamic "stickiness" {
    for_each = var.stickiness != null ? [var.stickiness] : []

    content {
      enabled         = stickiness.value.enabled
      type            = stickiness.value.stickiness_type
      cookie_duration = stickiness.value.duration
      cookie_name     = stickiness.value.stickiness_type == "app_cookie" ? stickiness.value.cookie_name : null
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-tg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener_rule" "this" {
  count = var.enable_load_balancer ? 1 : 0

  listener_arn = var.listener_arn
  priority     = var.listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[0].arn
  }

  dynamic "condition" {
    for_each = length(var.host_headers) > 0 ? [1] : []

    content {
      host_header {
        values = var.host_headers
      }
    }
  }

  dynamic "condition" {
    for_each = length(var.path_patterns) > 0 ? [1] : []

    content {
      path_pattern {
        values = var.path_patterns
      }
    }
  }

  tags = merge(var.tags, { Name = var.name })
}
