output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "IPv4 CIDR of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs, ordered by AZ. Load balancers only."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs, ordered by AZ. All workloads live here."
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "Availability Zones the VPC spans."
  value       = local.azs
}

output "nat_gateway_public_ips" {
  description = "Elastic IPs used for egress. Share these for third-party allowlists."
  value       = aws_eip.nat[*].public_ip
}

output "vpc_endpoint_security_group_id" {
  description = "Security group protecting the interface endpoints, or null when endpoints are disabled."
  value       = var.enable_vpc_endpoints ? aws_security_group.endpoints[0].id : null
}

output "flow_log_group_name" {
  description = "CloudWatch log group receiving VPC flow logs, or null when disabled."
  value       = var.enable_flow_logs ? aws_cloudwatch_log_group.flow_logs[0].name : null
}
