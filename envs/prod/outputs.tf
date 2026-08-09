output "vpc_id" {
  description = "ID of the environment VPC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnets running the workloads."
  value       = module.vpc.private_subnet_ids
}

output "nat_gateway_public_ips" {
  description = "Egress IPs for this environment. Share these for third-party allowlists."
  value       = module.vpc.nat_gateway_public_ips
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = module.ecs_cluster.cluster_name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = module.ecs_cluster.cluster_arn
}

output "alb_dns_name" {
  description = "Load balancer DNS name. Point application records at this."
  value       = module.alb.dns_name
}

output "alb_zone_id" {
  description = "Load balancer hosted zone ID, for ALIAS records."
  value       = module.alb.zone_id
}

output "alb_access_logs_bucket" {
  description = "Bucket holding ALB access logs."
  value       = module.alb.access_logs_bucket
}

output "certificate_arn" {
  description = "ACM certificate serving the HTTPS listener."
  value       = local.certificate_arn
}

output "waf_web_acl_arn" {
  description = "WAF web ACL protecting the load balancer, or null when disabled."
  value       = var.enable_waf ? module.waf[0].web_acl_arn : null
}

output "alarm_topic_arn" {
  description = "SNS topic that receives every alarm for this environment."
  value       = module.observability.alarm_topic_arn
}

output "kms_key_arn" {
  description = "Platform KMS key. Encrypt application secrets with this so tasks can decrypt them."
  value       = module.kms.key_arn
}

output "service_task_role_arns" {
  description = "Task role ARN per service. Grant application resource access to these principals."
  value       = { for k, m in module.service : k => m.task_role_arn }
}

output "service_log_groups" {
  description = "CloudWatch log group per service."
  value       = { for k, m in module.service : k => m.log_group_name }
}

output "service_connect_namespace" {
  description = "Internal DNS namespace for service-to-service discovery."
  value       = module.ecs_cluster.service_connect_namespace_name
}
