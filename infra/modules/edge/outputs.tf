output "zone_id" {
  value = local.zone_id
}

output "zone_arn" {
  value = local.zone_arn
}

output "name_servers" {
  description = "Delegate the domain to these if the zone was created here."
  value       = var.create_hosted_zone ? aws_route53_zone.this[0].name_servers : data.aws_route53_zone.this[0].name_servers
}

output "certificate_arn" {
  description = "Validated ACM certificate; goes in the Ingress alb.ingress.kubernetes.io/certificate-arn annotation."
  value       = aws_acm_certificate_validation.this.certificate_arn
}

output "web_acl_arn" {
  description = "Goes in the Ingress alb.ingress.kubernetes.io/wafv2-acl-arn annotation."
  value       = aws_wafv2_web_acl.this.arn
}
