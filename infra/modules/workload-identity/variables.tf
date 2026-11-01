variable "cluster_name" {
  type = string
}

variable "region" {
  type = string
}

variable "app_namespace" {
  description = "Namespace of the Next.js service (must match k8s/namespace.yaml)."
  type        = string
}

variable "app_service_account" {
  description = "Service account of the Next.js service (must match k8s/serviceaccount.yaml)."
  type        = string
}

variable "app_secrets_prefix" {
  description = "Secrets Manager name prefix the app may read, e.g. prod/next-bff-service/."
  type        = string
}

variable "log_bucket_arn" {
  type = string
}

variable "log_kms_key_arn" {
  type = string
}

variable "log_prefix" {
  description = "Key prefix Fluent Bit writes under."
  type        = string
  default     = "eks"
}

variable "hosted_zone_arn" {
  description = "Zone external-dns is allowed to change."
  type        = string
}
