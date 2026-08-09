###############################################################################
# Per-service CloudWatch alarms.
#
# `treat_missing_data` is chosen per alarm rather than globally: for the running
# task count, missing data means the service is gone, which is the outage you
# most want paged for. For error-rate alarms, missing data means no traffic.
###############################################################################

locals {
  alarms_enabled = var.enable_alarms
  t              = var.alarm_thresholds

  ecs_dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.name
  }

  alb_dimensions = var.enable_load_balancer ? {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = aws_lb_target_group.this[0].arn_suffix
  } : {}

  # Derived only from static inputs. `alb_arn_suffix` is unknown until the load
  # balancer exists, so testing it here would make `count` unresolvable at plan.
  alb_alarms_enabled = local.alarms_enabled && var.enable_load_balancer
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  count = local.alarms_enabled ? 1 : 0

  alarm_name        = "${var.name}-cpu-high"
  alarm_description = "${var.name} average CPU above ${local.t.cpu_utilization}% — autoscaling may be at max capacity."

  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  dimensions          = local.ecs_dimensions
  comparison_operator = "GreaterThanThreshold"
  threshold           = local.t.cpu_utilization
  period              = local.t.period_seconds
  evaluation_periods  = local.t.evaluation_periods
  datapoints_to_alarm = local.t.datapoints_to_alarm
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  count = local.alarms_enabled ? 1 : 0

  alarm_name        = "${var.name}-memory-high"
  alarm_description = "${var.name} average memory above ${local.t.memory_utilization}% — risk of OOM task kills."

  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  dimensions          = local.ecs_dimensions
  comparison_operator = "GreaterThanThreshold"
  threshold           = local.t.memory_utilization
  period              = local.t.period_seconds
  evaluation_periods  = local.t.evaluation_periods
  datapoints_to_alarm = local.t.datapoints_to_alarm
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = var.tags
}

# Missing data here means the service has stopped reporting entirely, so it is
# treated as breaching rather than ignored.
resource "aws_cloudwatch_metric_alarm" "running_tasks_low" {
  count = local.alarms_enabled ? 1 : 0

  alarm_name        = "${var.name}-running-tasks-low"
  alarm_description = "${var.name} has fewer than ${local.t.min_running_tasks + 1} running tasks — capacity or crash loop problem."

  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  statistic           = "Minimum"
  dimensions          = local.ecs_dimensions
  comparison_operator = "LessThanOrEqualToThreshold"
  threshold           = local.t.min_running_tasks
  period              = local.t.period_seconds
  evaluation_periods  = local.t.evaluation_periods
  datapoints_to_alarm = local.t.datapoints_to_alarm
  treat_missing_data  = "breaching"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  count = local.alb_alarms_enabled ? 1 : 0

  alarm_name        = "${var.name}-unhealthy-hosts"
  alarm_description = "${var.name} has targets failing ALB health checks."

  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  dimensions          = local.alb_dimensions
  comparison_operator = "GreaterThanThreshold"
  threshold           = local.t.unhealthy_host_count
  period              = local.t.period_seconds
  evaluation_periods  = local.t.evaluation_periods
  datapoints_to_alarm = local.t.datapoints_to_alarm
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  count = local.alb_alarms_enabled ? 1 : 0

  alarm_name        = "${var.name}-target-5xx"
  alarm_description = "${var.name} returned more than ${local.t.target_5xx_count} 5xx responses in a period."

  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  dimensions          = local.alb_dimensions
  comparison_operator = "GreaterThanThreshold"
  threshold           = local.t.target_5xx_count
  period              = local.t.period_seconds
  evaluation_periods  = local.t.evaluation_periods
  datapoints_to_alarm = local.t.datapoints_to_alarm
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = var.tags
}

# p95 rather than average: an average hides the tail that users actually feel.
resource "aws_cloudwatch_metric_alarm" "target_response_time" {
  count = local.alb_alarms_enabled ? 1 : 0

  alarm_name        = "${var.name}-latency-high"
  alarm_description = "${var.name} p95 latency above ${local.t.target_response_time}s."

  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  dimensions          = local.alb_dimensions
  comparison_operator = "GreaterThanThreshold"
  threshold           = local.t.target_response_time
  period              = local.t.period_seconds
  evaluation_periods  = local.t.response_time_periods
  datapoints_to_alarm = local.t.response_time_periods
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = var.tags
}
