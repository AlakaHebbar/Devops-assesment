variable "name" {
  description = "Name prefix for network resources."
  type        = string
}

variable "region" {
  description = "AWS region, used to build VPC endpoint service names."
  type        = string
}

variable "cidr" {
  description = "VPC CIDR block. Must not overlap with networks you may peer with later."
  type        = string
}

variable "azs" {
  description = "Availability zones to spread subnets across (at least 3 for production)."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "Use at least two availability zones."
  }
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway instead of one per AZ. Cheaper, but only for non-production."
  type        = bool
  default     = false
}

variable "interface_endpoints" {
  description = "Interface VPC endpoints to create, by service suffix."
  type        = list(string)
  default     = ["ecr.api", "ecr.dkr", "sts", "logs", "eks-auth", "secretsmanager"]
}

variable "flow_log_retention_days" {
  description = "Retention for VPC flow logs in CloudWatch."
  type        = number
  default     = 90
}
