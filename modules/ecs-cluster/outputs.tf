output "cluster_arn" {
  description = "ARN of the ECS cluster."
  value       = aws_ecs_cluster.this.arn
}

output "cluster_id" {
  description = "ID of the ECS cluster."
  value       = aws_ecs_cluster.this.id
}

output "cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.this.name
}

output "service_connect_namespace_arn" {
  description = "Cloud Map namespace ARN for Service Connect, or null when disabled."
  value       = local.create_namespace ? aws_service_discovery_private_dns_namespace.this[0].arn : null
}

output "service_connect_namespace_name" {
  description = "DNS name of the Service Connect namespace, or null when disabled."
  value       = local.create_namespace ? aws_service_discovery_private_dns_namespace.this[0].name : null
}

output "exec_log_group_name" {
  description = "CloudWatch log group holding the ECS Exec audit trail, or null when disabled."
  value       = var.enable_execute_command_logging ? aws_cloudwatch_log_group.exec[0].name : null
}

output "exec_log_group_arn" {
  description = "ARN of the ECS Exec audit log group, or null when disabled. Task roles need write access to it, otherwise exec sessions fail to start."
  value       = var.enable_execute_command_logging ? aws_cloudwatch_log_group.exec[0].arn : null
}
