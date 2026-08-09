output "state_bucket_name" {
  description = "S3 bucket holding Terraform state. Null when this root did not create one."
  value       = var.create_state_bucket ? aws_s3_bucket.state[0].id : null
}

output "state_kms_key_arn" {
  description = "KMS key ARN encrypting state objects. Null when this root did not create a bucket."
  value       = var.create_state_bucket ? aws_kms_key.state[0].arn : null
}

output "lock_table_name" {
  description = "DynamoDB table used for state locking. Null when this root did not create one."
  value       = var.create_lock_table ? aws_dynamodb_table.locks[0].name : null
}

output "backend_hcl" {
  description = "Ready-to-paste backend.hcl body for an environment root."
  value       = <<-EOT
    bucket         = "${var.create_state_bucket ? aws_s3_bucket.state[0].id : "<existing-bucket>"}"
    key            = "${var.project}/<env>/terraform.tfstate"
    region         = "${var.aws_region}"
    encrypt        = true
    dynamodb_table = "${var.create_lock_table ? aws_dynamodb_table.locks[0].name : "<existing-lock-table>"}"
    ${var.create_state_bucket ? "kms_key_id     = \"${aws_kms_key.state[0].arn}\"" : "# kms_key_id only applies to a bucket whose default encryption is SSE-KMS"}
  EOT
}
