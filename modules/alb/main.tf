###############################################################################
# Application Load Balancer.
#
# Port 80 exists only to redirect to 443. The HTTPS listener's default action is
# a deliberate 404: services attach themselves with listener rules, so an
# unrouted host header reaches nothing rather than whichever service happened to
# be registered first.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  create_logs_bucket = var.enable_access_logs

  # Regions enabled before August 2022 require the regional ELB account ID in
  # the bucket policy; newer regions use the log-delivery service principal.
  legacy_log_delivery_regions = [
    "us-east-1", "us-east-2", "us-west-1", "us-west-2",
    "af-south-1", "ap-east-1", "ap-south-1", "ap-northeast-1",
    "ap-northeast-2", "ap-northeast-3", "ap-southeast-1", "ap-southeast-2",
    "ap-southeast-3", "ca-central-1", "eu-central-1", "eu-west-1",
    "eu-west-2", "eu-west-3", "eu-north-1", "eu-south-1",
    "me-south-1", "sa-east-1",
  ]

  use_legacy_log_delivery = contains(local.legacy_log_delivery_regions, data.aws_region.current.region)

  access_logs_prefix     = "alb"
  connection_logs_prefix = "alb-connection"
}

# --- Security group -----------------------------------------------------------

resource "aws_security_group" "this" {
  name        = "${var.name}-alb"
  description = "Ingress to the ${var.name} load balancer"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each = toset(var.ingress_cidr_blocks)

  security_group_id = aws_security_group.this.id
  description       = "HTTPS from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "http_redirect" {
  # Port 80 is open only so the listener can 301 to HTTPS. Closing it would not
  # improve security; it would just break the redirect for http:// links.
  #checkov:skip=CKV_AWS_260:Port 80 exists solely to redirect to HTTPS and serves no content
  for_each = toset(var.ingress_cidr_blocks)

  security_group_id = aws_security_group.this.id
  description       = "HTTP from ${each.value}, redirected to HTTPS"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

# Egress is restricted to the VPC: every target this load balancer forwards to
# lives in a private subnet, so it has no legitimate reason to reach the
# internet. Service modules add the matching ingress rule on their own
# security groups.
resource "aws_vpc_security_group_egress_rule" "to_vpc" {
  security_group_id = aws_security_group.this.id
  description       = "Forwarding to targets inside the VPC"
  cidr_ipv4         = var.vpc_cidr_block
  ip_protocol       = "-1"
}

# --- Access log bucket --------------------------------------------------------

resource "aws_s3_bucket" "logs" {
  # Versioning, public-access block and lifecycle are configured in the
  # dedicated resources below; Checkov's graph does not follow them across a
  # counted resource. KMS is not usable here: ELB access-log delivery supports
  # SSE-S3 only. Event notifications serve no purpose on a log sink.
  #checkov:skip=CKV_AWS_21:Versioning is set in aws_s3_bucket_versioning.logs
  #checkov:skip=CKV_AWS_145:ELB access-log delivery supports SSE-S3 only, not KMS
  #checkov:skip=CKV2_AWS_6:Public access block is set in aws_s3_bucket_public_access_block.logs
  #checkov:skip=CKV2_AWS_61:Lifecycle is set in aws_s3_bucket_lifecycle_configuration.logs
  #checkov:skip=CKV2_AWS_62:Event notifications are not meaningful for a log sink
  #checkov:skip=CKV_AWS_18:A log bucket cannot usefully log its own access to itself
  #checkov:skip=CKV_AWS_144:Access logs are regional operational data, not worth cross-region replication
  count = local.create_logs_bucket ? 1 : 0

  bucket        = "${var.name}-alb-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.access_logs_bucket_force_destroy

  tags = merge(var.tags, { Name = "${var.name}-alb-logs" })
}

resource "aws_s3_bucket_public_access_block" "logs" {
  count = local.create_logs_bucket ? 1 : 0

  bucket                  = aws_s3_bucket.logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "logs" {
  count = local.create_logs_bucket ? 1 : 0

  bucket = aws_s3_bucket.logs[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ELB access log delivery supports SSE-S3 only, so a CMK cannot be used here.
# Trivy's own guidance for this check notes the same exception for log sinks.
#trivy:ignore:AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  count = local.create_logs_bucket ? 1 : 0

  bucket = aws_s3_bucket.logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "logs" {
  count = local.create_logs_bucket ? 1 : 0

  bucket = aws_s3_bucket.logs[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  count = local.create_logs_bucket ? 1 : 0

  bucket = aws_s3_bucket.logs[0].id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = var.access_logs_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.logs]
}

data "aws_elb_service_account" "this" {
  count = local.create_logs_bucket && local.use_legacy_log_delivery ? 1 : 0
}

data "aws_iam_policy_document" "logs" {
  count = local.create_logs_bucket ? 1 : 0

  dynamic "statement" {
    for_each = local.use_legacy_log_delivery ? [1] : []

    content {
      sid       = "AllowELBAccountWrite"
      effect    = "Allow"
      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.logs[0].arn}/*"]

      principals {
        type        = "AWS"
        identifiers = [data.aws_elb_service_account.this[0].arn]
      }
    }
  }

  statement {
    sid       = "AllowLogDeliveryWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs[0].arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    sid       = "AllowLogDeliveryAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.logs[0].arn]

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.logs[0].arn, "${aws_s3_bucket.logs[0].arn}/*"]

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

resource "aws_s3_bucket_policy" "logs" {
  count = local.create_logs_bucket ? 1 : 0

  bucket = aws_s3_bucket.logs[0].id
  policy = data.aws_iam_policy_document.logs[0].json

  depends_on = [aws_s3_bucket_public_access_block.logs]
}

# --- Load balancer ------------------------------------------------------------

# An internet-facing load balancer is the entire purpose of this module when
# internal = false. Exposure is a deliberate, reviewed choice, and everything
# behind it sits in private subnets.
#trivy:ignore:AWS-0053
resource "aws_lb" "this" {
  # Deletion protection is driven by var.enable_deletion_protection (true by
  # default, deliberately false in dev). The WAF web ACL is associated by the
  # waf module in the environment root, which Checkov cannot see from here.
  #checkov:skip=CKV_AWS_150:Deletion protection is environment-configurable and enabled in staging/prod
  #checkov:skip=CKV2_AWS_28:WAF is associated by the waf module in the environment root
  name               = var.name
  load_balancer_type = "application"
  internal           = var.internal
  subnets            = var.subnet_ids
  security_groups    = [aws_security_group.this.id]
  ip_address_type    = "ipv4"

  idle_timeout                     = var.idle_timeout
  enable_http2                     = var.enable_http2
  enable_cross_zone_load_balancing = var.enable_cross_zone_load_balancing
  enable_deletion_protection       = var.enable_deletion_protection
  drop_invalid_header_fields       = var.drop_invalid_header_fields
  desync_mitigation_mode           = var.desync_mitigation_mode
  preserve_host_header             = true

  dynamic "access_logs" {
    for_each = local.create_logs_bucket ? [1] : []

    content {
      bucket  = aws_s3_bucket.logs[0].id
      prefix  = local.access_logs_prefix
      enabled = true
    }
  }

  dynamic "connection_logs" {
    for_each = local.create_logs_bucket ? [1] : []

    content {
      bucket  = aws_s3_bucket.logs[0].id
      prefix  = local.connection_logs_prefix
      enabled = true
    }
  }

  tags = merge(var.tags, { Name = var.name })

  depends_on = [aws_s3_bucket_policy.logs]
}

# --- Listeners ----------------------------------------------------------------

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = var.tags
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = var.default_response_body
      status_code  = "404"
    }
  }

  tags = var.tags
}

resource "aws_lb_listener_certificate" "additional" {
  for_each = toset(var.additional_certificate_arns)

  listener_arn    = aws_lb_listener.https.arn
  certificate_arn = each.value
}
