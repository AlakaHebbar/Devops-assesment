# Consumed by infra/platform (via remote state) and by the k8s manifests.

output "region" {
  value = var.region
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "vpc_cidr" {
  value = module.network.vpc_cidr
}

output "nat_public_ips" {
  value = module.network.nat_public_ips
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "ci_image_publisher_role_arn" {
  value = module.ci_identity.image_publisher_role_arn
}

output "log_bucket_name" {
  value = module.log_archive.bucket_name
}

output "hosted_zone_id" {
  value = module.edge.zone_id
}

output "hosted_zone_name_servers" {
  value = module.edge.name_servers
}

output "domain_name" {
  value = var.domain_name
}

output "certificate_arn" {
  value = module.edge.certificate_arn
}

output "web_acl_arn" {
  value = module.edge.web_acl_arn
}

output "workload_role_arns" {
  value = module.workload_identity.role_arns
}

output "alerts_topic_arn" {
  value = module.observability.alerts_topic_arn
}
