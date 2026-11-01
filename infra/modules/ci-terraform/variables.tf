variable "name" {
  description = "Name prefix for IAM resources."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository whose workflows may assume the roles, as owner/name."
  type        = string
}

variable "oidc_provider_arn" {
  description = "GitHub OIDC provider ARN (from modules/ci-identity)."
  type        = string
}

variable "apply_environment" {
  description = "GitHub environment (with required reviewers) that gates the apply role."
  type        = string
  default     = "production"
}

variable "state_bucket_arn" {
  description = "Terraform state bucket from infra/bootstrap."
  type        = string
}

variable "plan_state_key" {
  description = "State object the plan role may read; the stack CI plans (infra.yml)."
  type        = string
  default     = "prod/core.tfstate"
}

variable "state_kms_key_arn" {
  description = "KMS key that encrypts the Terraform state."
  type        = string
}
