output "image_publisher_role_arn" {
  description = "Role for GitHub Actions (aws-actions/configure-aws-credentials role-to-assume)."
  value       = aws_iam_role.image_publisher.arn
}

output "oidc_provider_arn" {
  description = "GitHub OIDC provider ARN, shared with the Terraform CI roles."
  value       = local.provider_arn
}
