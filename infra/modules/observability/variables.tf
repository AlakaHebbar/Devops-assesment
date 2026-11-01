variable "name" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "service_namespace" {
  type = string
}

variable "service_name" {
  description = "Kubernetes Service name of the app."
  type        = string
}

variable "min_running_pods" {
  type    = number
  default = 2
}

variable "alert_emails" {
  description = "Email addresses subscribed to alerts (each must confirm the subscription)."
  type        = list(string)
  default     = []
}
