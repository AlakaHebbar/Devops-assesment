# AWS production architecture — Next.js on Amazon EKS

The Part 2 Next.js service (`next-bff-service`) runs on Amazon EKS in private subnets, pulls its image from a private Amazon ECR repository, and its logs are shipped to a private, KMS-encrypted Amazon S3 bucket. Everything is Terraform in [`infra/`](infra/). The diagram and the request/data flows are in [architecture/README.md](architecture/README.md) (Mermaid source: [architecture/architecture.mmd](architecture/architecture.mmd)).

The service is stateless, so there is no database. GitOps (Argo CD) and CI pipelines are planned for a later part; the IAM role CI needs to push images already exists.

## Stacks and apply order

| # | Stack | State | What it creates |
|---|---|---|---|
| 1 | [`infra/bootstrap`](infra/bootstrap) | local | S3 bucket + KMS key for Terraform state (versioned, TLS-only, public access blocked, S3 native locking) |
| 2 | [`infra/environments/prod`](infra/environments/prod) | `prod/core.tfstate` | VPC, EKS, ECR, IAM, Route 53/ACM/WAF, log bucket, alarms |
| 3 | [`infra/platform`](infra/platform) | `prod/platform.tfstate` | In-cluster controllers via Helm: AWS Load Balancer Controller, external-dns, metrics-server, Fluent Bit |
| 4 | [`k8s/`](k8s) | — | The service itself (`kubectl apply -k k8s/` for now, GitOps later) |

The platform stack has its own state because the Helm provider needs an existing cluster to connect to. Keeping it separate means a chart upgrade can never plan changes to the VPC or EKS. Step-by-step commands are in [infra/README.md](infra/README.md).

## What was created and why

### Network: [`modules/network`](infra/modules/network)

- **VPC across 3 AZs** (`10.20.0.0/16`): `/24` public subnets hold only the ALB and NAT gateways. `/19` private subnets hold nodes and pods, sized for VPC CNI pod IPs with prefix delegation.
- **One NAT gateway per AZ**, each private subnet routed to the NAT in its own AZ, so losing one AZ doesn't cut egress for the other two.
- **VPC endpoints**: a gateway endpoint for S3, plus interface endpoints for ECR API/DKR, STS, CloudWatch Logs, EKS Auth (Pod Identity) and Secrets Manager. Image pulls, log uploads and credential exchange stay on the AWS network and don't depend on NAT.
- **VPC flow logs** go to CloudWatch with 90-day retention. The **default security group has all its rules removed** so nothing can use it by accident.
- Subnets are tagged `kubernetes.io/role/elb` / `internal-elb` so the Load Balancer Controller places the ALB correctly.

### Kubernetes: [`modules/eks`](infra/modules/eks)

- **EKS 1.36, private API endpoint** (the public endpoint is off by default; if you turn it on, the module rejects `0.0.0.0/0`). Kubernetes Secrets are encrypted with a dedicated **KMS key**. All five **control-plane log types** go to a log group with set retention. **Zonal shift** is enabled.
- **Access entries** (`authentication_mode = API`) instead of the `aws-auth` ConfigMap. The cluster creator gets no implicit admin; only the role ARNs you list in `eks_admin_role_arns` do.
- **Managed node group** (AL2023, on-demand, `m7i/m6i.large`, 3–6 nodes) in the private subnets. Root volumes are encrypted gp3. **IMDSv2 is required with hop limit 1**, so pods can't borrow the node's IAM role. Node access is through SSM Session Manager; there are no SSH keys.
- **EKS-managed add-ons**: VPC CNI (with **network policy enforcement** and prefix delegation), kube-proxy, CoreDNS, the Pod Identity agent, and CloudWatch Observability (Container Insights metrics only).

### Registry: [`modules/ecr`](infra/modules/ecr) and CI identity: [`modules/ci-identity`](infra/modules/ci-identity)

- **ECR with immutable tags**, so a version or commit SHA always resolves to the same digest. It has **scan on push**, KMS encryption, and a lifecycle policy that drops untagged images after 7 days and keeps the last 50 tagged images for rollback.
- **GitHub Actions OIDC provider + `ci-image-publisher` role**: trust is limited to `repo:<owner/name>:ref:refs/heads/main` and `refs/tags/v*`. Permissions cover pushing to this one repository and nothing else. CI never holds long-lived AWS keys.
- Nodes pull with `AmazonEC2ContainerRegistryPullOnly`; no registry credentials are stored in the cluster.

### IAM for workloads: [`modules/workload-identity`](infra/modules/workload-identity)

Each workload gets its own IAM role, bound to its service account with **EKS Pod Identity**. The trust policy only allows `pods.eks.amazonaws.com` from this account:

| Role | Service account | Can do |
|---|---|---|
| `app` | `next-bff/next-bff-service` | Read Secrets Manager secrets under `prod/next-bff-service/*`. **No S3 access** |
| `fluent-bit` | `logging/fluent-bit` | `s3:PutObject` under `eks/*` in the log bucket + use its KMS key |
| `aws-load-balancer-controller` | `kube-system/aws-load-balancer-controller` | Upstream policy pinned to controller v3.6.0 |
| `external-dns` | `kube-system/external-dns` | Change records in the service's hosted zone only |

The EKS cluster, nodes, VPC flow logs and the CloudWatch agent each have their own service roles inside their modules.

### Edge, DNS and TLS: [`modules/edge`](infra/modules/edge)

- **Route 53**: by default the stack looks up an existing public hosted zone (`create_hosted_zone = true` creates one and adds a CAA record restricting issuance to Amazon). **external-dns** (platform stack) writes the alias record for the service hostname to the ALB, with `upsert-only` policy and TXT ownership records.
- **ACM certificate** for the hostname, validated through DNS automatically.
- **WAFv2 web ACL**: a per-IP rate limit plus the AWS IP Reputation, Common and Known Bad Inputs managed rule groups. WAF logs go to CloudWatch with the `Authorization` and `Cookie` headers redacted.
- The ALB itself comes from the Kubernetes Ingress. It has HTTP→HTTPS redirect, a TLS 1.3/1.2 policy, the WAF and certificate attached, deletion protection, and invalid headers dropped.

### Logs to object storage: [`modules/log-archive`](infra/modules/log-archive) + Fluent Bit

- The app writes JSON logs to stdout. **Fluent Bit** (a DaemonSet) tails the container logs, adds Kubernetes metadata, buffers on the node's disk, and writes gzip objects to `s3://<bucket>/eks/<cluster>/YYYY/MM/DD/HH/…`, retrying indefinitely.
- The bucket has **Block Public Access**, `BucketOwnerEnforced`, **SSE-KMS** with a dedicated key and bucket key, versioning, a TLS-only bucket policy, and lifecycle rules: Standard-IA at 30 days, Glacier IR at 90, expiry at 365 (configurable).
- Only the Fluent Bit role can write to it; the app can't touch the bucket.

### Monitoring: [`modules/observability`](infra/modules/observability)

A KMS-encrypted SNS alerts topic (with email subscriptions) and CloudWatch alarms for failed nodes, sustained node CPU above 80%, and fewer than 2 running service pods.

### Application runtime: [`k8s/`](k8s)

Restricted Pod Security Standard on the namespace. Non-root UID 1001, read-only root filesystem, all capabilities dropped, seccomp `RuntimeDefault`. Startup, readiness and liveness probes on `/api/health`. Resource requests and limits. Pods are spread across zones and hosts. **HPA** scales between 3 and 12 replicas. A **PDB** keeps at least 2 pods up. Rolling updates use `maxUnavailable: 0` and a `preStop` delay so the ALB drains a pod before it stops. A **NetworkPolicy** allows ingress only from the VPC on port 3000.

### Container image: [`application/Dockerfile`](application/Dockerfile)

A 3-stage build (deps → build → runner) using Next.js `standalone` output, so the runtime image contains only the traced production files. It uses an npm cache mount, runs as **numeric** `USER 1001:1001` (required for `runAsNonRoot` to be verifiable), has a `HEALTHCHECK` on `/api/health`, and OCI labels for version and commit. Images are tagged `<version>` or `<git sha>` and pushed to ECR. Because the tags are immutable, overwriting `latest`-style tags isn't possible.

## Production assumptions and follow-ups

- **Region / account**: `us-east-1` is the default. Run production in a dedicated account and keep non-production in separate accounts with their own `environments/<env>` directory.
- **Reaching the private API**: `infra/platform` and `kubectl` must run from inside the VPC (VPN, SSM port-forward, or a self-hosted runner). Alternatively, set `eks_endpoint_public_access` to an office/VPN CIDR.
- **Node autoscaling**: the node group has fixed min/max values. Add Karpenter or Cluster Autoscaler (with its own Pod Identity role) before relying on the HPA ceiling.
- **ALB alarms and access logs**: the ALB is created by the controller, so 5xx/latency alarms and ALB access logs (these need an SSE-S3 bucket) are added once its name is known.
- **CI/CD and GitOps**: a GitHub Actions workflow that assumes `ci_image_publisher_role_arn`, plus Argo CD reconciling `k8s/`. Both are planned for the next part. The environment-specific Ingress values (certificate ARN, WAF ARN, hostname) should become a kustomize overlay at that point.
- **Terraform in CI**: add a separate plan/apply role with approval gates; the current stacks assume an operator with admin rights.
