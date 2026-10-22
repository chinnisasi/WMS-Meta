output "state_bucket" {
  description = "Pass as -backend-config=\"bucket=…\" to every other stack's init."
  value       = aws_s3_bucket.state.bucket
}

output "state_kms_key_arn" {
  description = "The state bucket's KMS key."
  value       = aws_kms_key.state.arn
}
