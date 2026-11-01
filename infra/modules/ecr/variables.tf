variable "name" {
  description = "Repository name."
  type        = string
}

variable "max_tagged_images" {
  description = "How many tagged images to keep for rollbacks."
  type        = number
  default     = 50
}
