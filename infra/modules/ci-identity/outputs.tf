output "image_publisher_role_arn" {
  description = "Role for GitHub Actions (aws-actions/configure-aws-credentials role-to-assume)."
  value       = aws_iam_role.image_publisher.arn
}
