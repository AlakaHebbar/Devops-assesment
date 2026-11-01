variable "name" {
  description = "Name prefix for edge resources."
  type        = string
}

variable "hosted_zone_name" {
  description = "Public Route 53 hosted zone, e.g. example.com."
  type        = string
}

variable "create_hosted_zone" {
  description = "Create the hosted zone. Leave false when the zone already exists (the usual case for a production domain)."
  type        = bool
  default     = false
}

variable "domain_name" {
  description = "Hostname the service is served on, e.g. app.example.com."
  type        = string
}

variable "rate_limit_per_5_min" {
  description = "Requests per 5 minutes from one IP before WAF blocks it."
  type        = number
  default     = 2000
}

variable "waf_log_retention_days" {
  type    = number
  default = 30
}
