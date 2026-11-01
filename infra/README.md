# infra

Terraform for the production AWS environment. See [../ARCHITECTURE.md](../ARCHITECTURE.md) for what each piece is and why.

```
infra/
├── bootstrap/              # state bucket + KMS (local state, apply once)
├── environments/prod/      # core: VPC, EKS, ECR, IAM, Route 53/ACM/WAF, log bucket, alarms
├── platform/               # Helm: LB controller, external-dns, metrics-server, Fluent Bit, Argo CD
└── modules/
    ├── network/            # VPC, subnets, NAT per AZ, flow logs, VPC endpoints
    ├── eks/                # cluster, KMS, node group, add-ons, access entries
    ├── ecr/                # immutable private registry
    ├── ci-identity/        # GitHub OIDC + image publisher role
    ├── ci-terraform/       # Terraform plan (PR) and apply (production env) roles
    ├── ci-runner/          # CodeBuild-hosted GitHub Actions runner in the VPC
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

## 3. Platform stack

Run from a host that can reach the private EKS API (VPN / SSM / in-VPC runner).

```bash
cd infra/platform
terraform init -backend-config=../environments/prod/backend.hcl
terraform apply -var state_bucket=<state bucket>
```

## 4. GitOps and CI setup (once)

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

2. **CodeConnections.** Create a GitHub connection in the AWS console (Developer Tools → Connections) and approve it in GitHub. Put its ARN in `github_codeconnections_arn` before the core apply.
3. **GitHub environment.** Create an environment named `production` with required reviewers. Its deployment branches should be limited to `main`.
4. **GitHub variables and secrets.** Set the variables and secrets listed in [ARCHITECTURE.md](../ARCHITECTURE.md#secrets-and-ci-configuration). Most values come from:

   ```bash
   terraform -chdir=infra/environments/prod output
   ```

5. **Install Argo CD.** Apply the platform stack (step 3, or merge a PR and approve the pipeline). This installs Argo CD and the `next-bff-service` Application. From then on, everything in `k8s/` is deployed by Argo CD.

From here on, both stacks are applied by `.github/workflows/infra.yml`. Run applies locally only to break glass.

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
