###############################################################################
# Platform-level alerting: one SNS topic, the alarms that describe whether the
# edge is healthy, and a dashboard that answers "is it us or is it them?"
# without clicking through six consoles.
###############################################################################

data "aws_caller_identity" "current" {}

locals {
  # Both flags come from static inputs. The ARN suffix and web ACL name are only
  # known after apply, so deciding resource counts from them would break plan.
  alb_alarms_enabled = var.enable_alb_monitoring
  waf_alarms_enabled = var.enable_waf_monitoring

  alb_dimensions = local.alb_alarms_enabled ? { LoadBalancer = var.alb_arn_suffix } : {}
}

# --- Alerting topic -----------------------------------------------------------

resource "aws_sns_topic" "alarms" {
  name              = "${var.name}-alarms"
  kms_master_key_id = var.kms_key_arn

  tags = merge(var.tags, { Name = "${var.name}-alarms" })
}

data "aws_iam_policy_document" "alarms" {
  statement {
    sid       = "AllowCloudWatchPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alarms.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alarms.arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sns_topic_policy" "alarms" {
  arn    = aws_sns_topic.alarms.arn
  policy = data.aws_iam_policy_document.alarms.json
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alarm_email_subscriptions)

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_subscription" "https" {
  for_each = toset(var.alarm_https_subscriptions)

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "https"
  endpoint  = each.value
}

# --- Load balancer alarms -----------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  count = local.alb_alarms_enabled ? 1 : 0

  alarm_name        = "${var.name}-alb-5xx"
  alarm_description = "The load balancer itself returned 5xx responses — no healthy targets, or the ALB could not reach them."

  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  statistic           = "Sum"
  dimensions          = local.alb_dimensions
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alb_5xx_threshold
  period              = var.alarm_period_seconds
  evaluation_periods  = var.evaluation_periods
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_target_5xx" {
  count = local.alb_alarms_enabled ? 1 : 0

  alarm_name        = "${var.name}-alb-target-5xx"
  alarm_description = "Applications behind the load balancer are returning elevated 5xx responses."

  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  dimensions          = local.alb_dimensions
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alb_target_5xx_threshold
  period              = var.alarm_period_seconds
  evaluation_periods  = var.evaluation_periods
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_rejected_connections" {
  count = local.alb_alarms_enabled ? 1 : 0

  alarm_name        = "${var.name}-alb-rejected-connections"
  alarm_description = "The load balancer rejected connections — it has run out of surge queue capacity."

  namespace           = "AWS/ApplicationELB"
  metric_name         = "RejectedConnectionCount"
  statistic           = "Sum"
  dimensions          = local.alb_dimensions
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alb_rejected_connections_threshold
  period              = var.alarm_period_seconds
  evaluation_periods  = var.evaluation_periods
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = var.tags
}

# --- WAF alarm ----------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "waf_blocked" {
  count = local.waf_alarms_enabled ? 1 : 0

  alarm_name        = "${var.name}-waf-blocked-spike"
  alarm_description = "WAF is blocking an unusual volume of requests — likely an attack or a bad rule."

  namespace   = "AWS/WAFV2"
  metric_name = "BlockedRequests"
  statistic   = "Sum"

  dimensions = {
    WebACL = var.waf_web_acl_name
    Region = var.aws_region
    Rule   = "ALL"
  }

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.waf_blocked_requests_threshold
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = var.tags
}

# --- Dashboard ----------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "this" {
  count = var.create_dashboard ? 1 : 0

  dashboard_name = "${var.name}-${var.environment}"
  dashboard_body = jsonencode({ widgets = local.widgets })
}

locals {
  alb_traffic_widget = local.alb_alarms_enabled ? [
    {
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title  = "ALB request volume and errors"
        region = var.aws_region
        view   = "timeSeries"
        stat   = "Sum"
        period = 60
        metrics = [
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix],
          [".", "HTTPCode_Target_2XX_Count", ".", "."],
          [".", "HTTPCode_Target_4XX_Count", ".", "."],
          [".", "HTTPCode_Target_5XX_Count", ".", "."],
          [".", "HTTPCode_ELB_5XX_Count", ".", "."],
        ]
      }
    },
  ] : []

  alb_latency_widget = local.alb_alarms_enabled ? [
    {
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title  = "ALB target response time"
        region = var.aws_region
        view   = "timeSeries"
        period = 60
        metrics = [
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p50", label = "p50" }],
          ["...", { stat = "p95", label = "p95" }],
          ["...", { stat = "p99", label = "p99" }],
        ]
      }
    },
  ] : []

  service_cpu_widget = length(var.service_names) > 0 ? [
    {
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title  = "ECS service CPU utilisation"
        region = var.aws_region
        view   = "timeSeries"
        stat   = "Average"
        period = 60
        metrics = [
          for s in var.service_names :
          ["AWS/ECS", "CPUUtilization", "ClusterName", var.cluster_name, "ServiceName", s]
        ]
      }
    },
  ] : []

  service_memory_widget = length(var.service_names) > 0 ? [
    {
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title  = "ECS service memory utilisation"
        region = var.aws_region
        view   = "timeSeries"
        stat   = "Average"
        period = 60
        metrics = [
          for s in var.service_names :
          ["AWS/ECS", "MemoryUtilization", "ClusterName", var.cluster_name, "ServiceName", s]
        ]
      }
    },
  ] : []

  service_task_widget = length(var.service_names) > 0 ? [
    {
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title  = "Running tasks per service"
        region = var.aws_region
        view   = "timeSeries"
        stat   = "Average"
        period = 60
        metrics = [
          for s in var.service_names :
          ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", var.cluster_name, "ServiceName", s]
        ]
      }
    },
  ] : []

  waf_widget = local.waf_alarms_enabled ? [
    {
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title  = "WAF allowed vs blocked"
        region = var.aws_region
        view   = "timeSeries"
        stat   = "Sum"
        period = 300
        metrics = [
          ["AWS/WAFV2", "AllowedRequests", "WebACL", var.waf_web_acl_name, "Region", var.aws_region, "Rule", "ALL"],
          [".", "BlockedRequests", ".", ".", ".", ".", ".", "."],
        ]
      }
    },
  ] : []

  widgets = concat(
    local.alb_traffic_widget,
    local.alb_latency_widget,
    local.service_cpu_widget,
    local.service_memory_widget,
    local.service_task_widget,
    local.waf_widget,
  )
}
