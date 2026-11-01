# Minimum versions this module supports. Root stacks pin the exact versions
# (lock files), so modules use lower bounds rather than `~>` constraints.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}
