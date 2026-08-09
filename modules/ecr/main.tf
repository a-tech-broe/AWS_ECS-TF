###############################################################################
# ECR repositories.
#
# Tags are immutable by default so a deployed digest can never change under a
# running service, and lifecycle rules keep the registry from growing without
# bound. Scanning is on for every repository.
###############################################################################

locals {
  repositories = {
    for r in var.repositories :
    r => var.name_prefix != "" ? "${var.name_prefix}/${r}" : r
  }

  has_policy = length(var.pull_principal_arns) > 0 || length(var.push_principal_arns) > 0
}

resource "aws_ecr_repository" "this" {
  # scan_on_push is deliberately false only when this module also manages
  # registry-level ENHANCED (Inspector, continuous) scanning, which supersedes
  # it. Any other combination leaves scan-on-push enabled, so no path here
  # leaves images unscanned. Trivy evaluates the resolved plan and cannot see
  # the registry-level configuration that replaces it.
  #checkov:skip=CKV_AWS_163:Superseded by registry-level ENHANCED scanning
  #trivy:ignore:AWS-0030
  for_each = local.repositories

  name                 = each.value
  image_tag_mutability = var.image_tag_mutability
  force_delete         = var.force_delete

  image_scanning_configuration {
    # Registry-level ENHANCED scanning supersedes per-repository scan-on-push,
    # but only if this module actually manages that registry configuration.
    # Otherwise keep scan-on-push on, so no path leaves images unscanned.
    scan_on_push = !(var.enable_enhanced_scanning && var.manage_registry_scanning)
  }

  encryption_configuration {
    encryption_type = var.kms_key_arn != null ? "KMS" : "AES256"
    kms_key         = var.kms_key_arn
  }

  tags = merge(var.tags, { Name = each.value })
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the ${var.tagged_image_retention_count} most recent release images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = var.release_tag_prefixes
          countType     = "imageCountMoreThan"
          countNumber   = var.tagged_image_retention_count
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images after ${var.untagged_image_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_image_expiry_days
        }
        action = { type = "expire" }
      },
    ]
  })
}

# --- Repository access policy -------------------------------------------------

data "aws_iam_policy_document" "repository" {
  count = local.has_policy ? 1 : 0

  dynamic "statement" {
    for_each = length(var.pull_principal_arns) > 0 ? [1] : []

    content {
      sid    = "AllowPull"
      effect = "Allow"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
      ]

      principals {
        type        = "AWS"
        identifiers = var.pull_principal_arns
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.push_principal_arns) > 0 ? [1] : []

    content {
      sid    = "AllowPush"
      effect = "Allow"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:CompleteLayerUpload",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
      ]

      principals {
        type        = "AWS"
        identifiers = var.push_principal_arns
      }
    }
  }
}

resource "aws_ecr_repository_policy" "this" {
  for_each = local.has_policy ? aws_ecr_repository.this : {}

  repository = each.value.name
  policy     = data.aws_iam_policy_document.repository[0].json
}

# --- Registry-wide scanning ---------------------------------------------------

resource "aws_ecr_registry_scanning_configuration" "this" {
  count = var.manage_registry_scanning ? 1 : 0

  scan_type = var.enable_enhanced_scanning ? "ENHANCED" : "BASIC"

  rule {
    scan_frequency = var.enable_enhanced_scanning ? "CONTINUOUS_SCAN" : "SCAN_ON_PUSH"

    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }
}
