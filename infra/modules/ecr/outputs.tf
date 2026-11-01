output "repository_arn" {
  value = aws_ecr_repository.this.arn
}

output "repository_url" {
  value = aws_ecr_repository.this.repository_url
}

output "kms_key_arn" {
  value = aws_kms_key.ecr.arn
}
