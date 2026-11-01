# k8s/platform

Argo CD objects that the bootstrap's root application syncs (top level only).
Every add-on and the service itself is an ApplicationSet, using the cluster
generator. Values specific to an environment come from annotations on the
in-cluster Secret that `infra/gitops-bootstrap` writes (the "GitOps bridge"):

| Annotation | Source |
|---|---|
| `aws_region`, `cluster_name`, `vpc_id` | core stack |
| `log_bucket_name`, `hosted_zone_id` | core stack |
| `domain_name`, `certificate_arn`, `web_acl_arn` | core stack |
| `service_namespace`, `gitops_repo_url`, `gitops_revision` | bootstrap variables |

`values/` holds Helm values files referenced through multi-source
applications; it is not synced as manifests.
