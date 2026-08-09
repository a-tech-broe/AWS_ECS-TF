aws_region = "us-east-1"
project    = "ecs-platform"
repository = "AWS_ECS-TF"

ecr_name_prefix = "ecs-platform"

ecr_repositories = [
  "api",
  "web",
]

enable_enhanced_scanning = true
manage_registry_scanning = true

# --- DNS ----------------------------------------------------------------------
# One public hosted zone for the whole platform. Delegation is handled below,
# so no manual registrar step is needed.
create_route53_zone = true
route53_zone_name   = "skybroe.com"

# skybroe.com is registered in this account, so Terraform can repoint its name
# servers at the new zone directly. Its current NS records point at a Route 53
# zone that no longer exists here, so the domain does not resolve today.
manage_domain_delegation = true

# --- CI/CD --------------------------------------------------------------------
# Subjects name the repository explicitly; a wildcard here would let any
# repository on GitHub assume the apply role.

create_github_oidc = true

# The account already has an OIDC provider for token.actions.githubusercontent.com
# (verified 2026-08-09). It is a per-account singleton, so this root adopts the
# existing one by data lookup instead of creating a duplicate, which would fail
# the apply with EntityAlreadyExists.
create_oidc_provider = false

github_subjects = [
  "repo:a-tech-broe/AWS_ECS-TF:ref:refs/heads/main",
  "repo:a-tech-broe/AWS_ECS-TF:environment:shared",
  "repo:a-tech-broe/AWS_ECS-TF:environment:dev",
  "repo:a-tech-broe/AWS_ECS-TF:environment:staging",
  "repo:a-tech-broe/AWS_ECS-TF:environment:prod",
]

# State lives in the pre-existing bokiti123 bucket. No state_kms_key_arn: that
# bucket uses SSE-S3 (AES256), not a customer-managed key.
state_bucket_arn = "arn:aws:s3:::bokiti123"
