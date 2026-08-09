output "alarm_topic_arn" {
  description = "SNS topic ARN receiving alarm notifications. Pass this to service modules as alarm_actions."
  value       = aws_sns_topic.alarms.arn
}

output "alarm_topic_name" {
  description = "Name of the alarm SNS topic."
  value       = aws_sns_topic.alarms.name
}

output "dashboard_name" {
  description = "CloudWatch dashboard name, or null when the dashboard is disabled."
  value       = var.create_dashboard ? aws_cloudwatch_dashboard.this[0].dashboard_name : null
}
