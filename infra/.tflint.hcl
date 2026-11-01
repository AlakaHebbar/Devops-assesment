# Used by .github/workflows/infra.yml: tflint --recursive --config "$PWD/infra/.tflint.hcl"
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.50.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
