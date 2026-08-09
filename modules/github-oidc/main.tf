###############################################################################
# GitHub Actions OIDC federation.
#
# Two roles, deliberately: pull requests assume a read-only role that can plan,
# and only the protected branch/environment can assume the role that applies.
# No long-lived access keys exist anywhere in this design.
###############################################################################

locals {
  provider_url = "https://token.actions.githubusercontent.com"
  provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn

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

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1

  url = local.provider_url
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
  name                 = "${var.name}-gha-plan"
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
  name                 = "${var.name}-gha-apply"
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
