# Roles the infrastructure pipeline (.github/workflows/infra.yml) assumes with
# GitHub OIDC. Pull requests get a read-only plan role; only jobs running in the
# protected `production` GitHub environment (required reviewers) can assume the
# apply role, so nothing changes before a merge plus an approval.

data "aws_partition" "current" {}

locals {
  oidc_host     = "token.actions.githubusercontent.com"
  policy_prefix = "arn:${data.aws_partition.current.partition}:iam::aws:policy"
}

# --- Plan (pull requests) ----------------------------------------------------

data "aws_iam_policy_document" "plan_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # GitHub does not issue OIDC tokens to pull requests from forks.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["repo:${var.github_repository}:pull_request"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "${var.name}-ci-terraform-plan"
  assume_role_policy   = data.aws_iam_policy_document.plan_assume.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.plan.name
  policy_arn = "${local.policy_prefix}/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan" {
  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [var.state_bucket_arn, "${var.state_bucket_arn}/*"]
  }

  statement {
    sid       = "DecryptState"
    actions   = ["kms:Decrypt"]
    resources = [var.state_kms_key_arn]
  }

  # infra/platform reads the Argo CD deploy key at plan time.
  statement {
    sid       = "ReadGitOpsRepoKey"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.gitops_repo_secret_arn]
  }

  # ReadOnlyAccess can read every object in the account. Plans only need the
  # state bucket, so keep application logs and other data out of reach.
  statement {
    sid           = "DenyObjectReadsOutsideState"
    effect        = "Deny"
    actions       = ["s3:GetObject", "s3:GetObjectVersion"]
    not_resources = ["${var.state_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "plan" {
  name   = "terraform-plan"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan.json
}

# --- Apply (main, after approval) --------------------------------------------

data "aws_iam_policy_document" "apply_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only jobs that declare `environment: production`, which GitHub holds
    # until a required reviewer approves.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["repo:${var.github_repository}:environment:${var.apply_environment}"]
    }
  }
}

resource "aws_iam_role" "apply" {
  name                 = "${var.name}-ci-terraform-apply"
  assume_role_policy   = data.aws_iam_policy_document.apply_assume.json
  max_session_duration = 7200
}

# The stacks create IAM roles, KMS keys and networking, so the apply role needs
# broad rights. Scope it down (or add a permissions boundary) once the set of
# resource types settles.
resource "aws_iam_role_policy_attachment" "apply_admin" {
  role       = aws_iam_role.apply.name
  policy_arn = "${local.policy_prefix}/AdministratorAccess"
}
