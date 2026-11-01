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

# --- GitOps: Argo CD ---------------------------------------------------------
# Argo CD is the only thing that deploys the service. CI never talks to the
# cluster: it commits the new image tag to k8s/ and Argo CD syncs it.

# Read-only deploy key, stored in Secrets Manager by an operator (see the core
# stack). It lands in this stack's encrypted state and in the Argo CD repo
# Secret in-cluster (KMS envelope-encrypted), never in Git.
data "aws_secretsmanager_secret_version" "gitops_repo_key" {
  secret_id = local.core.gitops_repo_secret_arn
}

resource "helm_release" "argocd" {
  name             = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.11.6"

  values = [yamlencode({
    # HA layout: Redis HA across 3 nodes, two replicas of every stateless part.
    "redis-ha"     = { enabled = true }
    controller     = { replicas = 1 }
    server         = { replicas = 2, service = { type = "ClusterIP" } }
    repoServer     = { replicas = 2 }
    applicationSet = { replicas = 2 }
    # No SSO configured yet; operators use `kubectl port-forward` to the
    # ClusterIP server. Turn Dex/OIDC on before exposing the UI.
    dex = { enabled = false }

    configs = {
      cm = {
        # Poll Git every 3 minutes; a GitHub webhook to argocd-server can shorten this.
        "timeout.reconciliation" = "180s"
      }
      repositories = {
        "gitops-repo" = {
          name = "gitops-repo"
          type = "git"
          url  = var.gitops_repo_url
        }
      }
    }
  })]

  set_sensitive = [{
    name  = "configs.repositories.gitops-repo.sshPrivateKey"
    value = data.aws_secretsmanager_secret_version.gitops_repo_key.secret_string
    # Pass the multi-line PEM as-is, without Helm's --set parsing.
    type = "literal"
  }]

  depends_on = [helm_release.aws_load_balancer_controller]
}

# Project + Application for the service. The Application watches k8s/ on main
# and auto-syncs with prune and self-heal, so manual changes are reverted.
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.7"

  values = [yamlencode({
    projects = {
      "next-bff" = {
        namespace   = "argocd"
        description = "next-bff-service"
        sourceRepos = [var.gitops_repo_url]
        destinations = [{
          server    = "https://kubernetes.default.svc"
          namespace = var.service_namespace
        }]
        # The only cluster-scoped object the service owns.
        clusterResourceWhitelist = [{ group = "", kind = "Namespace" }]
      }
    }

    applications = {
      "next-bff-service" = {
        namespace = "argocd"
        project   = "next-bff"
        # No resources finalizer on purpose: deleting the Application must not
        # take production down with it.
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = var.gitops_revision
          path           = var.gitops_path
          kustomize = {
            # Environment values come from the core stack, so k8s/ stays free
            # of account IDs and ARNs.
            patches = [{
              target = { kind = "Ingress", name = "next-bff-service" }
              patch = yamlencode([
                { op = "add", path = "/spec/rules/0/host", value = local.core.domain_name },
                { op = "add", path = "/metadata/annotations/alb.ingress.kubernetes.io~1certificate-arn", value = local.core.certificate_arn },
                { op = "add", path = "/metadata/annotations/alb.ingress.kubernetes.io~1wafv2-acl-arn", value = local.core.web_acl_arn },
                { op = "add", path = "/metadata/annotations/external-dns.alpha.kubernetes.io~1hostname", value = local.core.domain_name },
              ])
            }]
          }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = var.service_namespace
        }
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
          syncOptions = [
            "CreateNamespace=false", # k8s/namespace.yaml carries the Pod Security labels
            "PrunePropagationPolicy=foreground",
            "RespectIgnoreDifferences=true",
          ]
          retry = {
            limit   = 5
            backoff = { duration = "10s", factor = 2, maxDuration = "3m" }
          }
        }
        # The HPA owns the replica count.
        ignoreDifferences = [{
          group        = "apps"
          kind         = "Deployment"
          name         = "next-bff-service"
          jsonPointers = ["/spec/replicas"]
        }]
      }
    }
  })]

  depends_on = [
    helm_release.argocd,
    helm_release.aws_load_balancer_controller,
    helm_release.external_dns,
    helm_release.metrics_server,
  ]
}
