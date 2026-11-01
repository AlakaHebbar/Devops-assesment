output "state_bucket" {
  description = "Use as `bucket` in the S3 backend of the other stacks."
  value       = aws_s3_bucket.state.bucket
}

output "state_kms_key_arn" {
  description = "Use as `kms_key_id` in the S3 backend of the other stacks."
  value       = aws_kms_key.state.arn
}
