###############################################################################
# WAFv2 regional web ACL fronting the ALB.
#
# Rule priorities are laid out so explicit allow/deny lists are evaluated before
# any managed rule group: an operator's decision should never be overridden by a
# heuristic. `count_mode` lets a new deployment observe real traffic before
# enforcement, which is how you avoid blocking customers on day one.
###############################################################################

locals {
  metric_prefix = replace(var.name, "-", "")

  # 0-9 reserved for IP allow/deny, 10+ for managed groups, 100+ for rate/geo.
  managed_rules = {
    for idx, rule in var.managed_rule_groups :
    rule.name => merge(rule, { priority = 10 + idx })
  }
}

resource "aws_wafv2_ip_set" "allowed" {
  count = length(var.allowed_ip_addresses) > 0 ? 1 : 0

  name               = "${var.name}-allowed"
  description        = "Trusted sources that bypass WAF inspection"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.allowed_ip_addresses

  tags = var.tags
}

resource "aws_wafv2_ip_set" "blocked" {
  count = length(var.blocked_ip_addresses) > 0 ? 1 : 0

  name               = "${var.name}-blocked"
  description        = "Sources denied before any other evaluation"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.blocked_ip_addresses

  tags = var.tags
}

resource "aws_wafv2_web_acl" "this" {
  name        = var.name
  description = "Regional web ACL for ${var.name}"
  scope       = "REGIONAL"

  default_action {
    dynamic "allow" {
      for_each = var.default_action == "allow" ? [1] : []
      content {}
    }

    dynamic "block" {
      for_each = var.default_action == "block" ? [1] : []
      content {}
    }
  }

  # Note: WAF inspects only the first 8 KB of a request body for ALB-associated
  # web ACLs, and that limit is not configurable (association_config covers
  # CloudFront, API Gateway, App Runner, Cognito and Verified Access only).
  # Enforce your own body-size limit in the application for anything larger.

  # --- Priority 0-9: explicit operator decisions ------------------------------

  dynamic "rule" {
    for_each = length(var.blocked_ip_addresses) > 0 ? [1] : []

    content {
      name     = "blocked-ips"
      priority = 0

      action {
        block {}
      }

      statement {
        ip_set_reference_statement {
          arn = aws_wafv2_ip_set.blocked[0].arn
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.metric_prefix}BlockedIPs"
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = length(var.allowed_ip_addresses) > 0 ? [1] : []

    content {
      name     = "allowed-ips"
      priority = 1

      action {
        allow {}
      }

      statement {
        ip_set_reference_statement {
          arn = aws_wafv2_ip_set.allowed[0].arn
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.metric_prefix}AllowedIPs"
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = length(var.blocked_country_codes) > 0 ? [1] : []

    content {
      name     = "geo-block"
      priority = 2

      action {
        block {}
      }

      statement {
        geo_match_statement {
          country_codes = var.blocked_country_codes
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.metric_prefix}GeoBlock"
        sampled_requests_enabled   = true
      }
    }
  }

  # --- Priority 10+: AWS managed rule groups ---------------------------------

  dynamic "rule" {
    for_each = local.managed_rules

    content {
      name     = rule.value.name
      priority = rule.value.priority

      # Managed groups carry their own actions; the ACL only overrides them.
      override_action {
        dynamic "count" {
          for_each = var.count_mode ? [1] : []
          content {}
        }

        dynamic "none" {
          for_each = var.count_mode ? [] : [1]
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = rule.value.vendor_name

          dynamic "rule_action_override" {
            for_each = toset(rule.value.count_overrides)

            content {
              name = rule_action_override.value

              action_to_use {
                count {}
              }
            }
          }

          dynamic "rule_action_override" {
            for_each = toset(rule.value.excluded_rules)

            content {
              name = rule_action_override.value

              action_to_use {
                allow {}
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.metric_prefix}${replace(rule.value.name, "AWSManagedRules", "")}"
        sampled_requests_enabled   = true
      }
    }
  }

  # --- Priority 100+: volumetric controls ------------------------------------

  dynamic "rule" {
    for_each = var.enable_rate_limiting ? [1] : []

    content {
      name     = "rate-limit"
      priority = 100

      action {
        dynamic "block" {
          for_each = var.count_mode ? [] : [1]
          content {}
        }

        dynamic "count" {
          for_each = var.count_mode ? [1] : []
          content {}
        }
      }

      statement {
        rate_based_statement {
          limit                 = var.rate_limit
          aggregate_key_type    = "IP"
          evaluation_window_sec = 300
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.metric_prefix}RateLimit"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.metric_prefix}WebACL"
    sampled_requests_enabled   = true
  }

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_wafv2_web_acl_association" "this" {
  for_each = var.resource_arns

  resource_arn = each.value
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}

# --- Logging ------------------------------------------------------------------

# WAF requires the destination log group name to start with "aws-waf-logs-".
resource "aws_cloudwatch_log_group" "waf" {
  count = var.enable_logging ? 1 : 0

  name              = "aws-waf-logs-${var.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  count = var.enable_logging ? 1 : 0

  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  dynamic "redacted_fields" {
    for_each = var.redact_authorization_header ? [1] : []

    content {
      single_header {
        name = "authorization"
      }
    }
  }

  dynamic "redacted_fields" {
    for_each = var.redact_authorization_header ? [1] : []

    content {
      single_header {
        name = "cookie"
      }
    }
  }
}
