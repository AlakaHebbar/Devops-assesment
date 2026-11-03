terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # One state file per environment, so the key is not fixed here. The bucket
  # comes from backend.hcl (see infra/environments/<env>/backend.hcl.example),
  # the key from the command line:
  #   terraform init -backend-config=backend.hcl -backend-config=key=<env>/core.tfstate
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Stack       = "core"
    }
  }
}
