variable "name" {
  description = "Name prefix for IAM resources."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository allowed to assume the role, as owner/name."
  type        = string
}

variable "allowed_refs" {
  description = "Git refs allowed to push images (wildcards allowed)."
  type        = list(string)
  default     = ["refs/heads/main", "refs/tags/v*"]
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if the account already has one."
  type        = bool
  default     = true
}

variable "existing_oidc_provider_arn" {
  description = "ARN of an existing GitHub OIDC provider, used when create_oidc_provider is false."
  type        = string
  default     = null
}

variable "ecr_repository_arn" {
  type = string
}

variable "ecr_kms_key_arn" {
  type = string
}
