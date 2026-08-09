output "arn" {
  description = "ARN of the load balancer."
  value       = aws_lb.this.arn
}

output "arn_suffix" {
  description = "ARN suffix used in CloudWatch metric dimensions."
  value       = aws_lb.this.arn_suffix
}

output "dns_name" {
  description = "DNS name of the load balancer. Point an ALIAS record at this."
  value       = aws_lb.this.dns_name
}

output "zone_id" {
  description = "Route 53 hosted zone ID of the load balancer, for ALIAS records."
  value       = aws_lb.this.zone_id
}

output "https_listener_arn" {
  description = "ARN of the HTTPS listener. Services attach their routing rules here."
  value       = aws_lb_listener.https.arn
}

output "http_listener_arn" {
  description = "ARN of the HTTP listener that redirects to HTTPS."
  value       = aws_lb_listener.http.arn
}

output "security_group_id" {
  description = "Security group of the load balancer. Reference this as the source in target security groups."
  value       = aws_security_group.this.id
}

output "access_logs_bucket" {
  description = "Bucket holding ALB access and connection logs, or null when disabled."
  value       = local.create_logs_bucket ? aws_s3_bucket.logs[0].id : null
}
