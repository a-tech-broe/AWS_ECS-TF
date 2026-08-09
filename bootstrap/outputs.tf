output "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform state. Use as `bucket` in each backend.hcl."
  value       = aws_s3_bucket.state.id
}

output "state_kms_key_arn" {
  description = "KMS key ARN encrypting state objects. Use as `kms_key_id` in each backend.hcl."
  value       = aws_kms_key.state.arn
}

output "backend_hcl" {
  description = "Ready-to-paste backend.hcl body for an environment root."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.id}"
    key          = "<env>/terraform.tfstate"
    region       = "${var.aws_region}"
    encrypt      = true
    kms_key_id   = "${aws_kms_key.state.arn}"
    use_lockfile = true
  EOT
}
