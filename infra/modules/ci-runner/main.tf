# AWS CodeBuild-hosted GitHub Actions runner inside the private subnets. The
# EKS API endpoint is private, so the infra/platform plan and apply jobs run
# here (`runs-on: codebuild-<project>-<run_id>-<attempt>`); every other job
# stays on GitHub-hosted runners. Each job gets a fresh, ephemeral container.
#
# The runner itself holds no AWS permissions beyond CodeBuild's own needs:
# jobs still assume the Terraform plan/apply roles through GitHub OIDC.

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  project_name = "${var.name}-gha-runner"
  project_arn  = "arn:${data.aws_partition.current.partition}:codebuild:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:project/${local.project_name}"
}

resource "aws_cloudwatch_log_group" "runner" {
  name              = "/aws/codebuild/${local.project_name}"
  retention_in_days = var.log_retention_days
}

# --- Network -----------------------------------------------------------------

resource "aws_security_group" "runner" {
  name        = local.project_name
  description = "GitHub Actions runner (CodeBuild)"
  vpc_id      = var.vpc_id
}

# HTTPS out: GitHub, Terraform/Helm registries (via NAT) and AWS APIs (via VPC
# endpoints). Nothing may connect in.
resource "aws_vpc_security_group_egress_rule" "runner_https" {
  security_group_id = aws_security_group.runner.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "cluster_api_from_runner" {
  security_group_id            = var.cluster_security_group_id
  description                  = "Kubernetes API from the GitHub Actions runner"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.runner.id
}

# --- IAM ---------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.project_arn]
    }
  }
}

resource "aws_iam_role" "runner" {
  name               = local.project_name
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "runner" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.runner.arn}:*"]
  }

  # ENIs for running inside the VPC.
  statement {
    sid = "VpcNetworking"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeDhcpOptions",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "VpcNetworkInterfacePermission"
    actions   = ["ec2:CreateNetworkInterfacePermission"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:network-interface/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:AuthorizedService"
      values   = ["codebuild.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "ec2:Subnet"
      values   = [for id in var.subnet_ids : "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:subnet/${id}"]
    }
  }

  statement {
    sid = "GitHubConnection"
    actions = [
      "codeconnections:GetConnection",
      "codeconnections:GetConnectionToken",
      "codeconnections:UseConnection",
    ]
    resources = [var.codeconnections_arn]
  }
}

resource "aws_iam_role_policy" "runner" {
  name   = "runner"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.runner.json
}

# --- Project -----------------------------------------------------------------

# Authorises CodeBuild to talk to GitHub through the CodeConnections connection
# (created once in the console and approved in GitHub; no token is stored here).
resource "aws_codebuild_source_credential" "github" {
  auth_type   = "CODECONNECTIONS"
  server_type = "GITHUB"
  token       = var.codeconnections_arn
}

resource "aws_codebuild_project" "runner" {
  name          = local.project_name
  description   = "Ephemeral GitHub Actions runners in the private subnets"
  service_role  = aws_iam_role.runner.arn
  build_timeout = 60

  source {
    type     = "GITHUB"
    location = "https://github.com/${var.github_repository}.git"
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type            = "LINUX_CONTAINER"
    compute_type    = var.compute_type
    image           = var.image
    privileged_mode = false
  }

  vpc_config {
    vpc_id             = var.vpc_id
    subnets            = var.subnet_ids
    security_group_ids = [aws_security_group.runner.id]
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.runner.name
    }
  }

  depends_on = [
    aws_codebuild_source_credential.github,
    aws_iam_role_policy.runner,
  ]
}

# Start a runner whenever a workflow job asks for this project's label.
resource "aws_codebuild_webhook" "runner" {
  project_name = aws_codebuild_project.runner.name
  build_type   = "BUILD"

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "WORKFLOW_JOB_QUEUED"
    }
  }
}
