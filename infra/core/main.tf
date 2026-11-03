locals {
  name = "${var.project}-${var.environment}"

  # GitHub environment whose jobs may assume this environment's apply role.
  # prod keeps its original name; infra.yml uses the same mapping.
  github_environment = var.environment == "prod" ? "production" : var.environment
}

module "network" {
  source = "../modules/network"

  name   = local.name
  region = var.region
  cidr   = var.vpc_cidr
  azs    = var.azs
}

module "eks" {
  source = "../modules/eks"

  name                         = local.name
  kubernetes_version           = var.kubernetes_version
  private_subnet_ids           = module.network.private_subnet_ids
  endpoint_public_access       = var.eks_endpoint_public_access
  endpoint_public_access_cidrs = var.eks_endpoint_public_access_cidrs
  node_instance_types          = var.node_instance_types
  node_min_size                = var.node_min_size
  node_desired_size            = var.node_desired_size
  node_max_size                = var.node_max_size
  # Humans only. CI roles get no access entry: the pipelines never call the
  # Kubernetes API, Argo CD is the only thing that changes the cluster.
  admin_role_arns = var.eks_admin_role_arns
}

module "ecr" {
  source = "../modules/ecr"

  name = var.service_name
}

module "ci_identity" {
  source = "../modules/ci-identity"

  name                       = local.name
  github_repository          = var.github_repository
  create_oidc_provider       = var.create_github_oidc_provider
  existing_oidc_provider_arn = var.existing_github_oidc_provider_arn
  ecr_repository_arn         = module.ecr.repository_arn
  ecr_kms_key_arn            = module.ecr.kms_key_arn
}

module "ci_terraform" {
  source = "../modules/ci-terraform"

  name              = local.name
  github_repository = var.github_repository
  oidc_provider_arn = module.ci_identity.oidc_provider_arn
  apply_environment = local.github_environment
  state_bucket_arn  = "arn:aws:s3:::${var.state_bucket_name}"
  plan_state_key    = "${var.environment}/core.tfstate"
  state_kms_key_arn = var.state_kms_key_arn
}

# Read-only GitHub deploy key Argo CD uses to pull this (private) repository.
# Terraform creates only the empty secret; an operator stores the private key,
# and infra/gitops-bootstrap hands it to Argo CD:
#   aws secretsmanager put-secret-value --secret-id <env>/argocd/repo-deploy-key \
#     --secret-string file://argocd-deploy-key
resource "aws_secretsmanager_secret" "gitops_repo_key" {
  name                    = "${var.environment}/argocd/repo-deploy-key"
  description             = "SSH deploy key (read-only) for Argo CD to pull ${var.github_repository}"
  recovery_window_in_days = 30
}

module "log_archive" {
  source = "../modules/log-archive"

  name           = local.name
  region         = var.region
  retention_days = var.log_retention_days
}

module "edge" {
  source = "../modules/edge"

  name               = local.name
  hosted_zone_name   = var.hosted_zone_name
  create_hosted_zone = var.create_hosted_zone
  domain_name        = var.domain_name
}

module "workload_identity" {
  source = "../modules/workload-identity"

  cluster_name        = module.eks.cluster_name
  region              = var.region
  app_namespace       = var.service_namespace
  app_service_account = var.service_name
  app_secrets_prefix  = "${var.environment}/${var.service_name}/"
  log_bucket_arn      = module.log_archive.bucket_arn
  log_kms_key_arn     = module.log_archive.kms_key_arn
  hosted_zone_arn     = module.edge.zone_arn
}

module "observability" {
  source = "../modules/observability"

  name              = local.name
  cluster_name      = module.eks.cluster_name
  service_namespace = var.service_namespace
  service_name      = var.service_name
  alert_emails      = var.alert_emails
}
