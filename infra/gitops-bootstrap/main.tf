# One-time GitOps bootstrap: install Argo CD and hand the cluster to it.
#
# After this, Argo CD manages everything in the cluster from Git, including the
# platform add-ons and Argo CD itself (k8s/platform/). CI never talks to the
# Kubernetes API. An operator applies this stack once per cluster, from a host
# that can reach the private EKS API (VPN or SSM port-forward), and again only
# to rebuild a cluster.

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
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    key          = "prod/gitops-bootstrap.tfstate"
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

  kube_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.core.cluster_name, "--region", var.region]
  }

  in_cluster = "https://kubernetes.default.svc"
}

provider "aws" {
  region = var.region
}

provider "helm" {
  kubernetes = {
    host                   = local.core.cluster_endpoint
    cluster_ca_certificate = base64decode(local.core.cluster_certificate_authority_data)
    exec                   = local.kube_exec
  }
}

provider "kubernetes" {
  host                   = local.core.cluster_endpoint
  cluster_ca_certificate = base64decode(local.core.cluster_certificate_authority_data)

  exec {
    api_version = local.kube_exec.api_version
    command     = local.kube_exec.command
    args        = local.kube_exec.args
  }
}

# --- Argo CD -----------------------------------------------------------------

# Initial install only. The argo-cd ApplicationSet in k8s/platform then manages
# the same chart from the same values file, so Terraform must not fight it.
resource "helm_release" "argocd" {
  name             = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.11.6"

  values = [file("${path.module}/../../k8s/platform/values/argo-cd.yaml")]

  lifecycle {
    ignore_changes = all
  }
}

# Read-only deploy key for this private repository, stored in Secrets Manager
# by an operator (the core stack creates the empty secret). It lands in this
# stack's encrypted state and in an in-cluster Secret (KMS envelope-encrypted),
# never in Git.
data "aws_secretsmanager_secret_version" "gitops_repo_key" {
  secret_id = local.core.gitops_repo_secret_arn
}

resource "kubernetes_secret_v1" "gitops_repo" {
  metadata {
    name      = "gitops-repo"
    namespace = helm_release.argocd.namespace
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type          = "git"
    url           = var.gitops_repo_url
    sshPrivateKey = data.aws_secretsmanager_secret_version.gitops_repo_key.secret_string
  }
}

# GitOps bridge: register the in-cluster destination with the core stack's
# outputs as annotations. The ApplicationSets in k8s/platform read them through
# the cluster generator, so Git holds no account IDs, ARNs or hostnames.
resource "kubernetes_secret_v1" "in_cluster" {
  metadata {
    name      = "in-cluster"
    namespace = helm_release.argocd.namespace
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
      "environment"                    = var.environment
    }
    annotations = {
      aws_region        = var.region
      cluster_name      = local.core.cluster_name
      vpc_id            = local.core.vpc_id
      vpc_cidr          = local.core.vpc_cidr
      log_bucket_name   = local.core.log_bucket_name
      hosted_zone_id    = local.core.hosted_zone_id
      domain_name       = local.core.domain_name
      certificate_arn   = local.core.certificate_arn
      web_acl_arn       = local.core.web_acl_arn
      service_namespace = var.service_namespace
      gitops_repo_url   = var.gitops_repo_url
      gitops_revision   = var.gitops_revision
    }
  }

  data = {
    name   = "in-cluster"
    server = local.in_cluster
    config = jsonencode({ tlsClientConfig = { insecure = false } })
  }
}

# --- Projects and the root application ---------------------------------------
# Projects are the security boundary between what Git may deploy and where, so
# they live here with the platform owners rather than in the synced directory.

resource "helm_release" "argocd_bootstrap" {
  name       = "argocd-bootstrap"
  namespace  = helm_release.argocd.namespace
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.7"

  values = [yamlencode({
    projects = {
      # The root application may only create ApplicationSets in argocd.
      "bootstrap" = {
        namespace    = "argocd"
        description  = "App-of-apps: ApplicationSets from k8s/platform"
        sourceRepos  = [var.gitops_repo_url]
        destinations = [{ server = local.in_cluster, namespace = "argocd" }]
        namespaceResourceWhitelist = [
          { group = "argoproj.io", kind = "ApplicationSet" },
        ]
      }

      # Cluster add-ons, including Argo CD itself. Their charts install CRDs,
      # ClusterRoles and webhooks, so cluster-scoped resources are allowed.
      "platform" = {
        namespace   = "argocd"
        description = "Cluster add-ons managed by Argo CD"
        sourceRepos = [
          var.gitops_repo_url,
          "https://argoproj.github.io/argo-helm",
          "https://aws.github.io/eks-charts",
          "https://kubernetes-sigs.github.io/external-dns",
          "https://kubernetes-sigs.github.io/metrics-server",
          "https://fluent.github.io/helm-charts",
        ]
        destinations = [
          { server = local.in_cluster, namespace = "argocd" },
          { server = local.in_cluster, namespace = "kube-system" },
          { server = local.in_cluster, namespace = "logging" },
        ]
        clusterResourceWhitelist = [{ group = "*", kind = "*" }]
      }

      # The service: this repository's k8s/ into its own namespace only.
      "next-bff" = {
        namespace    = "argocd"
        description  = "next-bff-service"
        sourceRepos  = [var.gitops_repo_url]
        destinations = [{ server = local.in_cluster, namespace = var.service_namespace }]
        # The only cluster-scoped object the service owns.
        clusterResourceWhitelist = [{ group = "", kind = "Namespace" }]
      }
    }

    applications = {
      "root" = {
        namespace = "argocd"
        project   = "bootstrap"
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = var.gitops_revision
          path           = "k8s/platform"
          # Top level only: values/ holds Helm values, not manifests.
          directory = { recurse = false }
        }
        destination = { server = local.in_cluster, namespace = "argocd" }
        syncPolicy = {
          automated = { prune = true, selfHeal = true }
        }
      }
    }
  })]

  depends_on = [
    kubernetes_secret_v1.gitops_repo,
    kubernetes_secret_v1.in_cluster,
  ]
}
