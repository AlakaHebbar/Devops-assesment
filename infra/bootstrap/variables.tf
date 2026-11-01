variable "project" {
  description = "Short project name used as a prefix for resource names."
  type        = string
  default     = "next-bff"
}

variable "region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "us-east-1"
}
