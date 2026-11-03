variable "project" {
  type    = string
  default = "next-bff"
}

variable "environment" {
  description = "Must match the state key (<environment>/core.tfstate). CI sets it from the matrix."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "uat", "prod"], var.environment)
    error_message = "environment must be dev, uat or prod."
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# --- Network ---

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

# --- EKS ---

variable "kubernetes_version" {
  type    = string
  default = "1.36"
}

variable "eks_endpoint_public_access" {
  description = "See modules/eks. Keep false and reach the API over VPN/SSM where possible."
  type        = bool
  default     = false
}

variable "eks_endpoint_public_access_cidrs" {
  type    = list(string)
  default = []
}

variable "eks_admin_role_arns" {
  description = "IAM roles that get cluster-admin (e.g. the IAM Identity Center admin role). Not CI roles: only Argo CD changes the cluster."
  type        = list(string)
}

variable "node_instance_types" {
  type    = list(string)
  default = ["m7i.large", "m6i.large"]
}

variable "node_min_size" {
  type    = number
  default = 3
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_max_size" {
  type    = number
  default = 6
}

# --- Service ---

variable "service_name" {
  description = "Used for the ECR repository, Kubernetes Service and service account names."
  type        = string
  default     = "next-bff-service"
}

variable "service_namespace" {
  type    = string
  default = "next-bff"
}

variable "github_repository" {
  description = "owner/name of the repository whose workflows may push images."
  type        = string
}

variable "create_github_oidc_provider" {
  type    = bool
  default = true
}

variable "existing_github_oidc_provider_arn" {
  type    = string
  default = null
}

# --- Terraform state (from infra/bootstrap; read by the CI plan role) ---

variable "state_bucket_name" {
  type = string
}

variable "state_kms_key_arn" {
  type = string
}

# --- Edge / DNS ---

variable "hosted_zone_name" {
  description = "Public Route 53 zone, e.g. example.com."
  type        = string
}

variable "create_hosted_zone" {
  type    = bool
  default = false
}

variable "domain_name" {
  description = "Service hostname, e.g. app.example.com."
  type        = string
}

# --- Logs / alerts ---

variable "log_retention_days" {
  type    = number
  default = 365
}

variable "alert_emails" {
  type    = list(string)
  default = []
}
