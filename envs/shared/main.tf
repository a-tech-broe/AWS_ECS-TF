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
  state_kms_key_arn    = var.state_kms_key_arn

  # Terraform manages ECS task roles, so the apply role needs IAM write access
  # that PowerUserAccess deliberately withholds.
  apply_inline_policy_json = data.aws_iam_policy_document.terraform_iam.json

  tags = local.tags
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
