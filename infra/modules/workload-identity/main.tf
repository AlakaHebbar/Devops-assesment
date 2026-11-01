# One IAM role per in-cluster workload, bound to its Kubernetes service account
# with EKS Pod Identity. Each role gets only what that workload needs.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
}

# --- Policies ----------------------------------------------------------------

# The app may only read its own secrets. It gets no S3 access: logs leave the
# pod via stdout and are shipped by Fluent Bit.
data "aws_iam_policy_document" "app" {
  statement {
    sid       = "ReadOwnSecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:${local.partition}:secretsmanager:${var.region}:${local.account_id}:secret:${var.app_secrets_prefix}*"]
  }
}

data "aws_iam_policy_document" "fluent_bit" {
  statement {
    sid       = "WriteLogObjects"
    actions   = ["s3:PutObject"]
    resources = ["${var.log_bucket_arn}/${var.log_prefix}/*"]
  }

  statement {
    sid       = "EncryptLogObjects"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.log_kms_key_arn]
  }
}

data "aws_iam_policy_document" "external_dns" {
  statement {
    sid       = "ChangeServiceZone"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [var.hosted_zone_arn]
  }

  statement {
    sid = "ListZones"
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResources",
    ]
    resources = ["*"]
  }
}

locals {
  workloads = {
    app = {
      namespace       = var.app_namespace
      service_account = var.app_service_account
      policy          = data.aws_iam_policy_document.app.json
    }
    fluent-bit = {
      namespace       = "logging"
      service_account = "fluent-bit"
      policy          = data.aws_iam_policy_document.fluent_bit.json
    }
    aws-load-balancer-controller = {
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
      # Upstream policy, pinned to the controller version in k8s/platform/aws-load-balancer-controller.yaml.
      policy = file("${path.module}/policies/aws-load-balancer-controller.json")
    }
    external-dns = {
      namespace       = "kube-system"
      service_account = "external-dns"
      policy          = data.aws_iam_policy_document.external_dns.json
    }
  }
}

# --- Roles and associations --------------------------------------------------

data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    # Only pods from this account's clusters may assume these roles.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = local.workloads

  name               = "${var.cluster_name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy" "this" {
  for_each = local.workloads

  name   = each.key
  role   = aws_iam_role.this[each.key].id
  policy = each.value.policy
}

resource "aws_eks_pod_identity_association" "this" {
  for_each = local.workloads

  cluster_name    = var.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.this[each.key].arn
}
