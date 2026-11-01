output "bucket_name" {
  value = aws_s3_bucket.logs.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.logs.arn
}

output "kms_key_arn" {
  value = aws_kms_key.logs.arn
}
