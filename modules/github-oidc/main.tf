###############################################################################
# GitHub Actions OIDC federation.
#
# Two roles, deliberately: pull requests assume a read-only role that can plan,
# and only the protected branch/environment can assume the role that applies.
# No long-lived access keys exist anywhere in this design.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  provider_url  = "https://token.actions.githubusercontent.com"
  provider_host = "token.actions.githubusercontent.com"

  # When adopting an existing provider the ARN is constructed rather than looked
  # up. A data source would need iam:ListOpenIDConnectProviders, which
  # PowerUserAccess denies, so the CI role that runs this module could not read
  # it. The ARN format is fixed and there is exactly one provider per host per
  # account, so constructing it is deterministic — and if the provider does not
  # exist, role creation fails immediately with an invalid-principal error.
  adopted_provider_arn = format(
    "arn:%s:iam::%s:oidc-provider/%s",
    data.aws_partition.current.partition,
    data.aws_caller_identity.current.account_id,
    local.provider_host,
  )

  provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : local.adopted_provider_arn

  plan_role_name  = coalesce(var.plan_role_name, "${var.name}-gha-plan")
  apply_role_name = coalesce(var.apply_role_name, "${var.name}-gha-apply")

  # Plan runs from pull requests; apply is restricted to whatever subjects the
  # caller listed, which should be branch- or environment-scoped.
  plan_subjects = distinct(concat(
    var.github_subjects,
    [for s in var.github_subjects : "${split(":ref:", s)[0]}:pull_request" if strcontains(s, ":ref:")],
  ))
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = local.provider_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = merge(var.tags, { Name = "${var.name}-github-oidc" })
}

data "aws_iam_policy_document" "assume_plan" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.plan_subjects
    }
  }
}

data "aws_iam_policy_document" "assume_apply" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.github_subjects
    }
  }
}

data "aws_iam_policy_document" "state_access" {
  count = var.state_bucket_arn != null ? 1 : 0

  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning"]
    resources = [var.state_bucket_arn]
  }

  statement {
    sid    = "ReadWriteState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${var.state_bucket_arn}/*"]
  }

  dynamic "statement" {
    for_each = var.state_lock_table_arn != null ? [1] : []

    content {
      sid    = "TakeStateLock"
      effect = "Allow"
      actions = [
        "dynamodb:DeleteItem",
        "dynamodb:DescribeTable",
        "dynamodb:GetItem",
        "dynamodb:PutItem",
      ]
      resources = [var.state_lock_table_arn]
    }
  }

  dynamic "statement" {
    for_each = var.state_kms_key_arn != null ? [1] : []

    content {
      sid    = "UseStateKey"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:Encrypt",
        "kms:GenerateDataKey",
      ]
      resources = [var.state_kms_key_arn]
    }
  }
}

# --- Plan role ----------------------------------------------------------------

resource "aws_iam_role" "plan" {
  name                 = local.plan_role_name
  description          = "Read-only role assumed by GitHub Actions to run terraform plan"
  assume_role_policy   = data.aws_iam_policy_document.assume_plan.json
  max_session_duration = var.max_session_duration

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "plan" {
  for_each = toset(var.plan_policy_arns)

  role       = aws_iam_role.plan.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "plan_state" {
  count = var.state_bucket_arn != null ? 1 : 0

  name   = "terraform-state"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.state_access[0].json
}

# --- Apply role ---------------------------------------------------------------

resource "aws_iam_role" "apply" {
  name                 = local.apply_role_name
  description          = "Role assumed by GitHub Actions to run terraform apply"
  assume_role_policy   = data.aws_iam_policy_document.assume_apply.json
  max_session_duration = var.max_session_duration

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "apply" {
  for_each = toset(var.apply_policy_arns)

  role       = aws_iam_role.apply.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "apply_state" {
  count = var.state_bucket_arn != null ? 1 : 0

  name   = "terraform-state"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.state_access[0].json
}

resource "aws_iam_role_policy" "apply_inline" {
  count = var.apply_inline_policy_json != null ? 1 : 0

  name   = "terraform-extra"
  role   = aws_iam_role.apply.id
  policy = var.apply_inline_policy_json
}
