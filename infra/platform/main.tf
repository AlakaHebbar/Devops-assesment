# Cluster add-ons the service depends on, installed after the core stack.
# Kept in a separate state so the Helm provider is configured from a cluster
# that already exists, and so platform upgrades never touch VPC/EKS resources.
#
# Must be run from somewhere that can reach the private EKS API endpoint
# (VPN, SSM port-forward, or a CI runner inside the VPC).

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    key          = "prod/platform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

data "terraform_remote_state" "core" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod/core.tfstate"
    region = var.region
  }
}

locals {
  core = data.terraform_remote_state.core.outputs
}

provider "aws" {
  region = var.region
}

provider "helm" {
  kubernetes = {
    host                   = local.core.cluster_endpoint
    cluster_ca_certificate = base64decode(local.core.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.core.cluster_name, "--region", var.region]
    }
  }
}

# --- Ingress: ALB from Kubernetes Ingress objects ----------------------------

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  # Keep in step with infra/modules/workload-identity/policies/aws-load-balancer-controller.json.
  version = "3.6.0"

  values = [yamlencode({
    clusterName  = local.core.cluster_name
    region       = var.region
    vpcId        = local.core.vpc_id
    replicaCount = 2
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
    }
    podDisruptionBudget = { maxUnavailable = 1 }
  })]
}

# --- DNS: Route 53 alias record for the Ingress hostname ---------------------

resource "helm_release" "external_dns" {
  name       = "external-dns"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/external-dns"
  chart      = "external-dns"
  version    = "1.22.0"

  values = [yamlencode({
    provider   = { name = "aws" }
    sources    = ["ingress"]
    policy     = "upsert-only"
    registry   = "txt"
    txtOwnerId = local.core.cluster_name
    extraArgs  = ["--zone-id-filter=${local.core.hosted_zone_id}"]
    env        = [{ name = "AWS_DEFAULT_REGION", value = var.region }]
    serviceAccount = {
      create = true
      name   = "external-dns"
    }
  })]

  depends_on = [helm_release.aws_load_balancer_controller]
}

# --- Metrics for HorizontalPodAutoscaler -------------------------------------

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/metrics-server"
  chart      = "metrics-server"
  version    = "3.13.0"

  values = [yamlencode({
    replicas            = 2
    podDisruptionBudget = { enabled = true, minAvailable = 1 }
  })]
}

# --- Logs: container stdout -> S3 --------------------------------------------

resource "helm_release" "fluent_bit" {
  name             = "fluent-bit"
  namespace        = "logging"
  create_namespace = true
  repository       = "https://fluent.github.io/helm-charts"
  chart            = "fluent-bit"
  version          = "0.58.0"

  values = [yamlencode({
    serviceAccount = {
      create = true
      name   = "fluent-bit"
    }
    tolerations = [{ operator = "Exists" }]
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { memory = "256Mi" }
    }
    config = {
      # Filesystem buffering on the node so logs survive pod restarts and S3 outages.
      service = <<-EOT
        [SERVICE]
            Daemon                    Off
            Flush                     5
            Log_Level                 info
            Parsers_File              /fluent-bit/etc/parsers.conf
            HTTP_Server               On
            HTTP_Listen               0.0.0.0
            HTTP_Port                 2020
            Health_Check              On
            storage.path              /var/log/flb-storage/
            storage.sync              normal
            storage.backlog.mem_limit 16M
      EOT

      inputs = <<-EOT
        [INPUT]
            Name              tail
            Tag               kube.*
            Path              /var/log/containers/*.log
            Exclude_Path      /var/log/containers/fluent-bit-*.log
            multiline.parser  cri
            DB                /var/log/flb_kube.db
            Mem_Buf_Limit     32MB
            Skip_Long_Lines   On
            storage.type      filesystem
      EOT

      filters = <<-EOT
        [FILTER]
            Name                kubernetes
            Match               kube.*
            Merge_Log           On
            Keep_Log            Off
            K8S-Logging.Exclude On
      EOT

      outputs = <<-EOT
        [OUTPUT]
            Name                     s3
            Match                    kube.*
            bucket                   ${local.core.log_bucket_name}
            region                   ${var.region}
            s3_key_format            /eks/${local.core.cluster_name}/%Y/%m/%d/%H/$TAG[4]-%M%S-$UUID.gz
            total_file_size          50M
            upload_timeout           5m
            use_put_object           On
            compression              gzip
            store_dir                /var/log/flb-s3
            Retry_Limit              False
      EOT
    }
  })]
}
