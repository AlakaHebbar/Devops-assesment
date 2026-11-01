variable "region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  description = "Matches the ApplicationSet cluster selectors in k8s/platform."
  type        = string
  default     = "prod"
}

variable "state_bucket" {
  description = "Terraform state bucket from infra/bootstrap (to read the core stack outputs)."
  type        = string
}

variable "gitops_repo_url" {
  description = "SSH URL of this repository, e.g. git@github.com:your-org/devops-challenge.git."
  type        = string
}

variable "gitops_revision" {
  description = "Branch Argo CD tracks."
  type        = string
  default     = "main"
}

variable "service_namespace" {
  type    = string
  default = "next-bff"
}
