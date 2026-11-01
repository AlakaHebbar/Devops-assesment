# infra

Terraform for the production AWS environment. See [../ARCHITECTURE.md](../ARCHITECTURE.md) for what each piece is and why.

```
infra/
├── bootstrap/              # state bucket + KMS (local state, apply once)
├── environments/prod/      # core: VPC, EKS, ECR, IAM, Route 53/ACM/WAF, log bucket, alarms
├── platform/               # Helm: LB controller, external-dns, metrics-server, Fluent Bit
└── modules/
    ├── network/            # VPC, subnets, NAT per AZ, flow logs, VPC endpoints
    ├── eks/                # cluster, KMS, node group, add-ons, access entries
    ├── ecr/                # immutable private registry
    ├── ci-identity/        # GitHub OIDC + image publisher role
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

## 4. Push the image and deploy the service

```bash
REPO=$(terraform -chdir=infra/environments/prod output -raw ecr_repository_url)
TAG=$(git rev-parse --short HEAD)
aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO%%/*}"
docker build --build-arg VERSION="$TAG" --build-arg GIT_SHA="$TAG" -t "$REPO:$TAG" application
docker push "$REPO:$TAG"
```

Set the image tag in `k8s/kustomization.yaml`, and the hostname, `certificate_arn` and `web_acl_arn` outputs in `k8s/ingress.yaml`. Then:

```bash
aws eks update-kubeconfig --name next-bff-prod
kubectl apply -k k8s/
```
