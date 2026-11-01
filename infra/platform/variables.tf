variable "region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket" {
  description = "Terraform state bucket from infra/bootstrap (to read the core stack outputs)."
  type        = string
}
