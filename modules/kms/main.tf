###############################################################################
# Customer-managed KMS key with a policy assembled from the service principals
# that actually need it. Callers pass only the principals they use, so each key
# stays least-privilege instead of falling back to a blanket "*" grant.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  root_arn   = "arn:${local.partition}:iam::${local.account_id}:root"

  # CloudWatch Logs uses a regional principal and must be scoped by encryption
  # context, so it cannot share the generic service statement below.
  logs_principal = "logs.${local.region}.amazonaws.com"
}

resource "aws_kms_key" "this" {
  description             = var.description
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = true
  multi_region            = var.multi_region
  policy                  = data.aws_iam_policy_document.key.json
  tags                    = merge(var.tags, { Name = var.alias })
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.alias}"
  target_key_id = aws_kms_key.this.key_id
}

data "aws_iam_policy_document" "key" {
  # A KMS key policy is attached to the key itself, so "*" as the resource means
  # "this key" and cannot be narrowed further. The root-account statement is
  # mandatory: without it the key becomes unmanageable.
  #checkov:skip=CKV_AWS_109:Resource "*" in a key policy scopes to the key it is attached to
  #checkov:skip=CKV_AWS_111:Key administration is constrained to explicitly listed principals
  #checkov:skip=CKV_AWS_356:Key policies cannot reference the key ARN they are attached to

  # Without this the key becomes unmanageable the moment the creating identity
  # loses access. Required on every CMK.
  statement {
    sid       = "AccountRootFullAccess"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.root_arn]
    }
  }

  dynamic "statement" {
    for_each = length(var.service_principals) > 0 ? [1] : []

    content {
      sid    = "AllowServiceUse"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:Encrypt",
        "kms:GenerateDataKey*",
        "kms:ReEncrypt*",
      ]
      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = var.service_principals
      }

      # Confused-deputy guard: the calling service must be acting for this
      # account. Disabled for principals that call without SourceAccount.
      dynamic "condition" {
        for_each = var.enable_source_account_condition ? [1] : []

        content {
          test     = "StringEquals"
          variable = "aws:SourceAccount"
          values   = [local.account_id]
        }
      }
    }
  }

  dynamic "statement" {
    for_each = var.enable_cloudwatch_logs ? [1] : []

    content {
      sid    = "AllowCloudWatchLogs"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:Encrypt",
        "kms:GenerateDataKey*",
        "kms:ReEncrypt*",
      ]
      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = [local.logs_principal]
      }

      condition {
        test     = "ArnLike"
        variable = "kms:EncryptionContext:aws:logs:arn"
        values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.key_administrator_arns) > 0 ? [1] : []

    content {
      sid    = "AllowKeyAdministration"
      effect = "Allow"
      actions = [
        "kms:Create*",
        "kms:Describe*",
        "kms:Disable*",
        "kms:Enable*",
        "kms:Get*",
        "kms:List*",
        "kms:Put*",
        "kms:Revoke*",
        "kms:ScheduleKeyDeletion",
        "kms:TagResource",
        "kms:UntagResource",
        "kms:Update*",
      ]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = var.key_administrator_arns
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.key_user_arns) > 0 ? [1] : []

    content {
      sid    = "AllowKeyUse"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:Encrypt",
        "kms:GenerateDataKey*",
        "kms:ReEncrypt*",
      ]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = var.key_user_arns
      }
    }
  }

  # Autoscaling and other services attach grants on behalf of the caller.
  dynamic "statement" {
    for_each = length(var.grant_creator_service_principals) > 0 ? [1] : []

    content {
      sid    = "AllowGrantsForAWSResources"
      effect = "Allow"
      actions = [
        "kms:CreateGrant",
        "kms:ListGrants",
        "kms:RevokeGrant",
      ]
      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = var.grant_creator_service_principals
      }

      condition {
        test     = "Bool"
        variable = "kms:GrantIsForAWSResource"
        values   = ["true"]
      }
    }
  }
}
