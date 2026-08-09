###############################################################################
# Terraform state backend.
#
# Applied once per account with local state, then left alone. Every environment
# root in envs/ stores its state in this bucket under a distinct key, and takes
# a lock in the DynamoDB table below.
#
# Both halves are optional. An account that already has a state bucket and lock
# table (as this one does — s3://bokiti123 and the family_dyning table) should
# set create_state_bucket = false and create_lock_table = false, or skip this
# root entirely. Creating a bucket that already exists fails the apply, and a
# shared bucket's settings should not be taken over by this configuration.
###############################################################################

data "aws_caller_identity" "current" {}

locals {
  bucket_name = coalesce(
    var.state_bucket_name != "" ? var.state_bucket_name : null,
    "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}",
  )

  lock_table_name = coalesce(
    var.lock_table_name != "" ? var.lock_table_name : null,
    "${var.project}-tflock",
  )

  create_bucket = var.create_state_bucket
}

# --- KMS key used to encrypt state objects -----------------------------------

resource "aws_kms_key" "state" {
  count = local.create_bucket ? 1 : 0

  description             = "Encrypts Terraform state for ${var.project}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.state_key[0].json
}

resource "aws_kms_alias" "state" {
  count = local.create_bucket ? 1 : 0

  name          = "alias/${var.project}-tfstate"
  target_key_id = aws_kms_key.state[0].key_id
}

data "aws_iam_policy_document" "state_key" {
  #checkov:skip=CKV_AWS_109:Resource "*" in a key policy scopes to the key it is attached to
  #checkov:skip=CKV_AWS_111:Required root-account statement; without it the key is unmanageable
  #checkov:skip=CKV_AWS_356:Key policies cannot reference the key ARN they are attached to
  count = local.create_bucket ? 1 : 0

  statement {
    sid       = "AccountRootFullAccess"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  dynamic "statement" {
    for_each = length(var.trusted_principal_arns) > 0 ? [1] : []

    content {
      sid    = "TrustedPrincipalsUseKey"
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
        identifiers = var.trusted_principal_arns
      }
    }
  }
}

# --- State bucket -------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV2_AWS_62:Event notifications are not meaningful for a Terraform state bucket
  #checkov:skip=CKV_AWS_18:Access to state is audited through CloudTrail, not S3 server access logs
  #checkov:skip=CKV_AWS_144:Versioning plus CloudTrail covers the recovery case; replication is a separate DR decision
  # The four below are configured in the sibling resources under this one.
  # Checkov's graph stops following them once the resources are counted.
  #checkov:skip=CKV_AWS_21:Versioning is set in aws_s3_bucket_versioning.state
  #checkov:skip=CKV_AWS_145:SSE-KMS with the CMK is set in aws_s3_bucket_server_side_encryption_configuration.state
  #checkov:skip=CKV2_AWS_6:Public access block is set in aws_s3_bucket_public_access_block.state
  #checkov:skip=CKV2_AWS_61:Lifecycle is set in aws_s3_bucket_lifecycle_configuration.state
  count = local.create_bucket ? 1 : 0

  bucket = local.bucket_name

  # State is the single source of truth for the platform; make accidental
  # `terraform destroy` of this root a no-op rather than an outage.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  count = local.create_bucket ? 1 : 0

  bucket = aws_s3_bucket.state[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  count = local.create_bucket ? 1 : 0

  bucket = aws_s3_bucket.state[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state[0].arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  count = local.create_bucket ? 1 : 0

  bucket                  = aws_s3_bucket.state[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  count = local.create_bucket ? 1 : 0

  bucket = aws_s3_bucket.state[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  count = local.create_bucket ? 1 : 0

  bucket = aws_s3_bucket.state[0].id

  rule {
    id     = "expire-noncurrent-state"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = var.noncurrent_version_retention_days
      newer_noncurrent_versions = 10
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

resource "aws_s3_bucket_policy" "state" {
  count = local.create_bucket ? 1 : 0

  bucket = aws_s3_bucket.state[0].id
  policy = data.aws_iam_policy_document.state_bucket[0].json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

data "aws_iam_policy_document" "state_bucket" {
  count = local.create_bucket ? 1 : 0

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state[0].arn, "${aws_s3_bucket.state[0].arn}/*"]

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

  statement {
    sid       = "DenyUnencryptedObjectUploads"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state[0].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }
}

# --- State lock table ---------------------------------------------------------
#
# Terraform requires a single "LockID" string hash key and nothing else.
# On-demand billing is correct here: lock traffic is a handful of requests per
# apply, so provisioned capacity would be pure waste.

resource "aws_dynamodb_table" "locks" {
  count = var.create_lock_table ? 1 : 0

  name         = local.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = local.create_bucket
    kms_key_arn = local.create_bucket ? aws_kms_key.state[0].arn : null
  }

  # Losing the lock table lets two applies run concurrently and corrupt state.
  deletion_protection_enabled = true

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = local.lock_table_name
  }
}
