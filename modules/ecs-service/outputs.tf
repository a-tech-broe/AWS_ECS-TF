output "service_name" {
  description = "Name of the ECS service."
  value       = aws_ecs_service.this.name
}

output "service_arn" {
  description = "ARN of the ECS service."
  value       = aws_ecs_service.this.id
}

output "task_definition_arn" {
  description = "ARN of the current task definition revision."
  value       = aws_ecs_task_definition.this.arn
}

output "task_definition_family" {
  description = "Task definition family name."
  value       = aws_ecs_task_definition.this.family
}

output "task_role_arn" {
  description = "ARN of the application task role. Grant resource access to this principal."
  value       = aws_iam_role.task.arn
}

output "task_role_name" {
  description = "Name of the application task role."
  value       = aws_iam_role.task.name
}

output "execution_role_arn" {
  description = "ARN of the ECS execution role."
  value       = aws_iam_role.execution.arn
}

output "security_group_id" {
  description = "Security group attached to the tasks."
  value       = aws_security_group.this.id
}

output "target_group_arn" {
  description = "ARN of the target group, or null for services without a load balancer."
  value       = var.enable_load_balancer ? aws_lb_target_group.this[0].arn : null
}

output "target_group_arn_suffix" {
  description = "Target group ARN suffix for CloudWatch metric dimensions."
  value       = var.enable_load_balancer ? aws_lb_target_group.this[0].arn_suffix : null
}

output "log_group_name" {
  description = "CloudWatch log group receiving container logs."
  value       = aws_cloudwatch_log_group.this.name
}
