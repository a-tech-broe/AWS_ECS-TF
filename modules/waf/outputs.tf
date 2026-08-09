output "web_acl_arn" {
  description = "ARN of the web ACL."
  value       = aws_wafv2_web_acl.this.arn
}

output "web_acl_id" {
  description = "ID of the web ACL."
  value       = aws_wafv2_web_acl.this.id
}

output "web_acl_name" {
  description = "Name of the web ACL, used as the CloudWatch metric dimension."
  value       = aws_wafv2_web_acl.this.name
}

output "log_group_name" {
  description = "CloudWatch log group receiving WAF logs, or null when logging is disabled."
  value       = var.enable_logging ? aws_cloudwatch_log_group.waf[0].name : null
}
