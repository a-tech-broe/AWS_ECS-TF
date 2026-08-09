###############################################################################
# Account-level singletons.
#
# ECR and the GitHub OIDC provider live here rather than in each environment:
# an image should be built once and promoted dev -> staging -> prod by digest,
# and an OIDC provider is a per-account resource that two roots cannot both own.
###############################################################################

locals {
  name = var.project

  tags = merge(var.tags, {
    Component = "shared"
  })

  dns_query_logging = var.create_route53_zone && var.enable_dns_query_logging
}

module "ecr_kms" {
  source = "../../modules/kms"

  alias       = "${local.name}-ecr"
  description = "Encrypts container images in ECR for ${local.name}"

  # ECR encrypts repositories through grants it creates on the caller's behalf.
  grant_creator_service_principals = ["ecr.amazonaws.com"]
  service_principals               = ["ecr.amazonaws.com"]

  tags = local.tags
}

module "ecr" {
  source = "../../modules/ecr"

  repositories             = var.ecr_repositories
  name_prefix              = var.ecr_name_prefix
  kms_key_arn              = module.ecr_kms.key_arn
  image_tag_mutability     = "IMMUTABLE"
  enable_enhanced_scanning = var.enable_enhanced_scanning
  manage_registry_scanning = var.manage_registry_scanning
  force_delete             = var.ecr_force_delete

  tags = local.tags
}

module "github_oidc" {
  source = "../../modules/github-oidc"
  count  = var.create_github_oidc ? 1 : 0

  name                 = local.name
  create_oidc_provider = var.create_oidc_provider
  github_subjects      = var.github_subjects
  state_bucket_arn     = var.state_bucket_arn
  state_lock_table_arn = var.state_lock_table_arn
  state_kms_key_arn    = var.state_kms_key_arn

  # Terraform manages ECS task roles, so the apply role needs IAM write access
  # that PowerUserAccess deliberately withholds.
  apply_inline_policy_json = data.aws_iam_policy_document.terraform_iam.json

  tags = local.tags
}

# --- DNS ----------------------------------------------------------------------
#
# A single public hosted zone lives here rather than per environment: the zone is
# the delegation point for the whole domain, and three roots each owning a copy
# would fight over the same NS records. Environments look it up by name.
resource "aws_route53_zone" "this" {
  # DNSSEC is deliberately not enabled: it only takes effect once DS records are
  # published at the registrar, and a half-configured chain of trust makes the
  # domain unresolvable rather than merely unsigned. Turn it on as a considered
  # step after delegation is stable, not as part of first stand-up.
  #checkov:skip=CKV2_AWS_38:DNSSEC requires registrar DS records; enabling it blind can take the domain offline
  #checkov:skip=CKV2_AWS_39:Query logging is enabled via aws_route53_query_log.this; the graph does not follow it across counted resources
  count = var.create_route53_zone ? 1 : 0

  name    = var.route53_zone_name
  comment = "Public zone for ${local.name}"

  tags = local.tags
}

# skybroe.com is registered in this account, so the delegation loop can be closed
# here instead of by hand at a registrar: Route 53 assigns the zone four name
# servers, and this points the registered domain at exactly those. Destroying it
# removes the record from state only — it never deletes the domain.
resource "aws_route53domains_registered_domain" "this" {
  provider = aws.us_east_1

  count = var.create_route53_zone && var.manage_domain_delegation ? 1 : 0

  domain_name = var.route53_zone_name

  dynamic "name_server" {
    for_each = aws_route53_zone.this[0].name_servers

    content {
      name = name_server.value
    }
  }
}

# Query logging must live in us-east-1 and write to a log group whose name
# begins with /aws/route53/. Route 53 writes through a CloudWatch Logs resource
# policy rather than an IAM role.
resource "aws_cloudwatch_log_group" "dns_queries" {
  provider = aws.us_east_1

  #checkov:skip=CKV_AWS_158:Route 53 query logging does not support CMK-encrypted log groups
  #checkov:skip=CKV_AWS_338:Retention is set per account via dns_query_log_retention_days
  count = local.dns_query_logging ? 1 : 0

  name              = "/aws/route53/${var.route53_zone_name}"
  retention_in_days = var.dns_query_log_retention_days

  tags = local.tags
}

data "aws_iam_policy_document" "route53_query_logging" {
  count = local.dns_query_logging ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:log-group:/aws/route53/*"]

    principals {
      type        = "Service"
      identifiers = ["route53.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "route53_query_logging" {
  provider = aws.us_east_1

  count = local.dns_query_logging ? 1 : 0

  policy_name     = "${local.name}-route53-query-logging"
  policy_document = data.aws_iam_policy_document.route53_query_logging[0].json
}

resource "aws_route53_query_log" "this" {
  count = local.dns_query_logging ? 1 : 0

  zone_id                  = aws_route53_zone.this[0].zone_id
  cloudwatch_log_group_arn = aws_cloudwatch_log_group.dns_queries[0].arn

  depends_on = [aws_cloudwatch_log_resource_policy.route53_query_logging]
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "terraform_iam" {
  # Role management is scoped to this account's roles, PassRole is bound by
  # iam:PassedToService, and an explicit Deny protects the CI roles themselves.
  # Service-linked role actions genuinely cannot be resource-scoped.
  #checkov:skip=CKV_AWS_109:Scoped to account roles with an explicit self-modification Deny
  #checkov:skip=CKV_AWS_356:CreateServiceLinkedRole cannot be resource-scoped
  statement {
    sid    = "ManageServiceRoles"
    effect = "Allow"
    actions = [
      "iam:AttachRolePolicy",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:PutRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*"]
  }

  # Privilege-escalation guard: the pipeline manages workload roles, but must
  # never be able to widen its own. Deny beats Allow, so this holds even if the
  # attached managed policies are broadened later.
  statement {
    sid    = "DenySelfModification"
    effect = "Deny"
    actions = [
      "iam:AttachRolePolicy",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-gha-plan",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-gha-apply",
    ]
  }

  # PassRole is the classic escalation path, so bound it to the services this
  # platform actually hands roles to.
  statement {
    sid       = "PassRolesToPlatformServices"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "ecs-tasks.amazonaws.com",
        "ecs.amazonaws.com",
        "application-autoscaling.amazonaws.com",
        "vpc-flow-logs.amazonaws.com",
        "delivery.logs.amazonaws.com",
      ]
    }
  }

  statement {
    sid    = "ManageServiceLinkedRoles"
    effect = "Allow"
    actions = [
      "iam:CreateServiceLinkedRole",
      "iam:DeleteServiceLinkedRole",
      "iam:GetServiceLinkedRoleDeletionStatus",
    ]
    resources = ["*"]
  }
}
