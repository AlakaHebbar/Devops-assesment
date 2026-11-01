variable "region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket" {
  description = "Terraform state bucket from infra/bootstrap (to read the core stack outputs)."
  type        = string
}

# --- GitOps (Argo CD) ---

variable "gitops_repo_url" {
  description = "SSH URL of this repository, e.g. git@github.com:your-org/devops-challenge.git."
  type        = string
}

variable "gitops_revision" {
  description = "Branch Argo CD tracks."
  type        = string
  default     = "main"
}

variable "gitops_path" {
  description = "Directory with the service's kustomization."
  type        = string
  default     = "k8s"
}

variable "service_namespace" {
  type    = string
  default = "next-bff"
}
