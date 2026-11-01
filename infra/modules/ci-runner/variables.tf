variable "name" {
  description = "Name prefix for the runner resources."
  type        = string
}

variable "github_repository" {
  description = "Repository the runner serves, as owner/name."
  type        = string
}

variable "codeconnections_arn" {
  description = "AWS CodeConnections GitHub connection ARN (create it in the console and approve the GitHub app once)."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnets the runner ENIs are placed in."
  type        = list(string)
}

variable "cluster_security_group_id" {
  description = "EKS cluster security group; the runner is allowed in on 443 to reach the private API."
  type        = string
}

variable "compute_type" {
  type    = string
  default = "BUILD_GENERAL1_SMALL"
}

variable "image" {
  description = "CodeBuild image; it includes the AWS CLI that the Helm provider uses for `aws eks get-token`."
  type        = string
  default     = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
}

variable "log_retention_days" {
  type    = number
  default = 90
}
