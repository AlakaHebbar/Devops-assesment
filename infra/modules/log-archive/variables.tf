variable "name" {
  description = "Name prefix for the bucket."
  type        = string
}

variable "region" {
  type = string
}

variable "retention_days" {
  description = "Days to keep log objects before they expire. Align with your compliance requirements."
  type        = number
  default     = 365
}
