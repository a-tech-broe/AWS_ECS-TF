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
# One public hosted zone for the whole platform. After applying, take the
# route53_name_servers output and set exactly those NS records at the domain's
# registrar. Until that delegation exists, ACM validation cannot complete.
create_route53_zone = true
route53_zone_name   = "skybroe.com"

# skybroe.com is registered in this account, so Terraform can repoint its name
# servers at the new zone directly. Its current NS records point at a Route 53
# zone that no longer exists here, so the domain does not resolve today.
manage_domain_delegation = true

# --- CI/CD --------------------------------------------------------------------
# Replace <owner> with the GitHub org or user that owns this repository.
# Subjects must name the repository explicitly; a wildcard here would let any
# repository on GitHub assume the apply role.

create_github_oidc = true

github_subjects = [
  "repo:<owner>/AWS_ECS-TF:ref:refs/heads/main",
  "repo:<owner>/AWS_ECS-TF:environment:shared",
  "repo:<owner>/AWS_ECS-TF:environment:dev",
  "repo:<owner>/AWS_ECS-TF:environment:staging",
  "repo:<owner>/AWS_ECS-TF:environment:prod",
]

# Populate from the `bootstrap` outputs so CI can read and write state.
# state_bucket_arn  = "arn:aws:s3:::ecs-platform-tfstate-<account-id>"
# state_kms_key_arn = "arn:aws:kms:us-east-1:<account-id>:key/<key-id>"
