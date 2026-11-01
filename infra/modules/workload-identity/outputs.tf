output "role_arns" {
  description = "Pod Identity role ARN per workload."
  value       = { for k, r in aws_iam_role.this : k => r.arn }
}
