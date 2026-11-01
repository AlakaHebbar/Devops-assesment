output "plan_role_arn" {
  description = "Role for `terraform plan` on pull requests."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Role for `terraform apply` in the production GitHub environment."
  value       = aws_iam_role.apply.arn
}
