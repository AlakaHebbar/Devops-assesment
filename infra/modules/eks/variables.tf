variable "name" {
  description = "Cluster name."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the control-plane ENIs and the nodes."
  type        = list(string)
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API publicly (restricted to endpoint_public_access_cidrs). Keep false when operators reach the API through VPN/SSM."
  type        = bool
  default     = false
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint when it is enabled."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "Do not open the Kubernetes API to the whole internet."
  }
}

variable "admin_role_arns" {
  description = "IAM role ARNs (e.g. IAM Identity Center admin role, infra deploy role) granted cluster-admin through EKS access entries."
  type        = list(string)
  default     = []
}

variable "control_plane_log_retention_days" {
  type    = number
  default = 90
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

variable "node_disk_size_gib" {
  type    = number
  default = 50
}

variable "view_role_arns" {
  description = "IAM role ARNs granted cluster-wide read access (AmazonEKSAdminViewPolicy), e.g. the Terraform plan role."
  type        = list(string)
  default     = []
}
