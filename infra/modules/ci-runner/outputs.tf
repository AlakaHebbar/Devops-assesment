output "project_name" {
  description = "Use in workflows as runs-on: codebuild-<project_name>-$${{ github.run_id }}-$${{ github.run_attempt }}."
  value       = aws_codebuild_project.runner.name
}
