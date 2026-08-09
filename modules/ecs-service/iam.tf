###############################################################################
# Task execution role (what ECS itself uses: pull the image, fetch secrets,
# write logs) and task role (what the application code uses). Keeping these
# separate means a compromised application never inherits registry or secret
# access it was not explicitly given.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  secret_arns = values(var.secrets)

  # Secrets Manager ARNs carry a six-character random suffix and may be followed
  # by json-key/version-stage/version-id segments. IAM must reference the secret
  # ARN itself, so trim anything past the name segment.
  secretsmanager_arns = distinct([
    for arn in local.secret_arns :
    join(":", slice(split(":", arn), 0, 7))
    if length(split(":", arn)) >= 7 && split(":", arn)[2] == "secretsmanager"
  ])

  ssm_parameter_arns = distinct([
    for arn in local.secret_arns :
    arn if split(":", arn)[2] == "ssm"
  ])
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # Confused-deputy guard: only tasks in this account's clusters may assume.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:ecs:${local.region}:${local.account_id}:*"]
    }
  }
}

# --- Execution role -----------------------------------------------------------

resource "aws_iam_role" "execution" {
  name                 = "${var.name}-ecs-execution"
  description          = "ECS agent role for the ${var.name} service"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume.json
  max_session_duration = 3600

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid    = "WriteServiceLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  dynamic "statement" {
    for_each = length(local.secretsmanager_arns) > 0 ? [1] : []

    content {
      sid       = "ReadSecretsManagerSecrets"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = local.secretsmanager_arns
    }
  }

  dynamic "statement" {
    for_each = length(local.ssm_parameter_arns) > 0 ? [1] : []

    content {
      sid    = "ReadSSMParameters"
      effect = "Allow"
      actions = [
        "ssm:GetParameter",
        "ssm:GetParameters",
      ]
      resources = local.ssm_parameter_arns
    }
  }

  dynamic "statement" {
    for_each = var.kms_key_arn != null && length(local.secret_arns) > 0 ? [1] : []

    content {
      sid       = "DecryptSecrets"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [var.kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "${var.name}-execution"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

resource "aws_iam_role_policy" "execution_extra" {
  count = var.execution_role_extra_policy_json != null ? 1 : 0

  name   = "${var.name}-execution-extra"
  role   = aws_iam_role.execution.id
  policy = var.execution_role_extra_policy_json
}

# --- Task role ----------------------------------------------------------------

resource "aws_iam_role" "task" {
  name                 = "${var.name}-ecs-task"
  description          = "Application role for the ${var.name} service"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume.json
  max_session_duration = 3600

  tags = var.tags
}

data "aws_iam_policy_document" "task_exec" {
  count = var.enable_execute_command ? 1 : 0

  statement {
    sid    = "AllowECSExecChannel"
    effect = "Allow"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.kms_key_arn != null ? [1] : []

    content {
      sid       = "AllowECSExecSessionEncryption"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [var.kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "task_exec" {
  count = var.enable_execute_command ? 1 : 0

  name   = "${var.name}-ecs-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_exec[0].json
}

resource "aws_iam_role_policy" "task_application" {
  count = var.task_role_policy_json != null ? 1 : 0

  name   = "${var.name}-application"
  role   = aws_iam_role.task.id
  policy = var.task_role_policy_json
}
