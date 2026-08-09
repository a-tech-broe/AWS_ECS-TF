output "ecr_repository_urls" {
  description = "Registry URLs keyed by short repository name. Use these to build the `image` value for each service."
  value       = module.ecr.repository_urls
}

output "ecr_kms_key_arn" {
  description = "KMS key encrypting ECR images."
  value       = module.ecr_kms.key_arn
}

output "github_plan_role_arn" {
  description = "Role ARN for the plan job. Set as the AWS_PLAN_ROLE_ARN repository variable."
  value       = var.create_github_oidc ? module.github_oidc[0].plan_role_arn : null
}

output "github_apply_role_arn" {
  description = "Role ARN for the apply job. Set as the AWS_APPLY_ROLE_ARN repository variable."
  value       = var.create_github_oidc ? module.github_oidc[0].apply_role_arn : null
}

output "route53_zone_id" {
  description = "Hosted zone ID, or null when the zone is not managed here."
  value       = var.create_route53_zone ? aws_route53_zone.this[0].zone_id : null
}

output "route53_name_servers" {
  description = "Name servers for the zone. Certificate validation cannot succeed until the domain's registrar delegates to exactly these."
  value       = var.create_route53_zone ? aws_route53_zone.this[0].name_servers : null
}
