# infra

Terraform for the production AWS environment. See [../ARCHITECTURE.md](../ARCHITECTURE.md) for what each piece is and why.

```
infra/
├── bootstrap/              # state bucket + KMS (local state, apply once)
├── environments/prod/      # core: VPC, EKS, ECR, IAM, Route 53/ACM/WAF, log bucket, alarms
├── gitops-bootstrap/       # once, by an operator: Argo CD + root app (add-ons then come from k8s/platform)
└── modules/
    ├── network/            # VPC, subnets, NAT per AZ, flow logs, VPC endpoints
    ├── eks/                # cluster, KMS, node group, add-ons, access entries
    ├── ecr/                # immutable private registry
    ├── ci-identity/        # GitHub OIDC + image publisher role
    ├── ci-terraform/       # Terraform plan (PR) and apply (production env) roles
    ├── workload-identity/  # Pod Identity roles (app, fluent-bit, LBC, external-dns)
    ├── log-archive/        # S3 log bucket
    ├── edge/               # Route 53, ACM, WAFv2
    └── observability/      # SNS + CloudWatch alarms
```

Requires Terraform >= 1.10 (S3 native state locking) and AWS credentials with admin rights in the target account.

## 1. Bootstrap state (once per account)

```bash
cd infra/bootstrap
terraform init
terraform apply
```

## 2. Core stack

```bash
cd infra/environments/prod
cp backend.hcl.example backend.hcl            # fill from bootstrap outputs
cp terraform.tfvars.example terraform.tfvars  # fill in admin roles, repo, domain
terraform init -backend-config=backend.hcl
terraform plan -out=core.tfplan
terraform apply core.tfplan
```

If `create_hosted_zone = true`, delegate the domain to `hosted_zone_name_servers` before the ACM validation can finish.

## 3. GitOps and CI setup (once)

1. **Deploy key for Argo CD.** The repository is private, so Argo CD needs a read-only key.
   1. Generate a key pair:

      ```bash
      ssh-keygen -t ed25519 -N "" -C argocd -f argocd-deploy-key
      ```

   2. Add `argocd-deploy-key.pub` in GitHub under Settings → Deploy keys, with write access off.
   3. Store the private key in Secrets Manager, then delete the local files:

      ```bash
      aws secretsmanager put-secret-value --secret-id prod/argocd/repo-deploy-key \
        --secret-string file://argocd-deploy-key
      ```

2. **GitHub environment.** Create an environment named `production` with required reviewers. Its deployment branches should be limited to `main`.
3. **GitHub variables and secrets.** Set the variables and secrets listed in [ARCHITECTURE.md](../ARCHITECTURE.md#secrets-and-ci-configuration). Most values come from:

   ```bash
   terraform -chdir=infra/environments/prod output
   ```

From here on, the core stack is applied by `.github/workflows/infra.yml`. Run applies locally only to break glass.

## 4. GitOps bootstrap (once per cluster)

This is the only Terraform that talks to Kubernetes. Run it from a host that can reach the private EKS API (VPN or SSM port-forward), with one of the `eks_admin_role_arns` roles.

```bash
cd infra/gitops-bootstrap
terraform init -backend-config=../environments/prod/backend.hcl
terraform apply \
  -var state_bucket=<state bucket> \
  -var gitops_repo_url=git@github.com:<owner>/<repo>.git
```

It installs Argo CD, the repository and cluster Secrets, the AppProjects and the root application. Argo CD then syncs [`k8s/platform/`](../k8s/platform), which deploys:
- the AWS Load Balancer Controller
- external-dns
- metrics-server
- Fluent Bit
- the service
- Argo CD itself

From then on, every change inside the cluster, including add-on and Argo CD upgrades, is a commit. Re-run this stack only to rebuild a cluster, or after core outputs it publishes change, such as the hostname or certificate.

## 5. Deploy and roll back the service

- **Deploy:** merge to `main`. `app-ci` builds, scans and pushes `<ecr>/next-bff-service:<sha>`, then commits that tag to `k8s/kustomization.yaml`. Argo CD syncs it.
- **Roll back:** revert the deploy commit:

  ```bash
  git revert <deploy-commit> && git push
  ```

- **Check status** from a host that can reach the API:

  ```bash
  kubectl -n argocd get applications
  ```

- **Argo CD UI:**

  ```bash
  kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:443
  ```

  The initial admin password is in the `argocd-initial-admin-secret` Secret.
