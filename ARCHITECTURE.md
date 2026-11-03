# AWS production architecture — Next.js on Amazon EKS

The Part 2 Next.js service (`next-bff-service`) runs on Amazon EKS in private subnets. It pulls its image from a private Amazon ECR repository, and its logs go to a private, KMS-encrypted Amazon S3 bucket. All the AWS infrastructure is Terraform in [`infra/`](infra/).

Delivery is GitOps:
- **GitHub Actions** builds the image and commits the new tag to [`k8s/`](k8s).
- **Argo CD** is the only thing that changes the cluster. Terraform installs it once (an operator-run bootstrap). From then on Argo CD deploys the service, the platform add-ons and itself from Git.
- **Infrastructure changes** are planned on pull requests and applied only after a merge and a reviewer's approval. That pipeline only calls AWS APIs; no CI job has Kubernetes credentials.

![Infrastructure diagram: VPC across three AZs in us-east-1, EKS, edge and IAM roles](architecture/infrastructure.png)

Three diagrams, one per question:
- **Where it runs:** [infrastructure.png](architecture/infrastructure.png) (above).
- **What runs in the cluster:** [k8s-components.png](architecture/k8s-components.png), in [Application runtime](#application-runtime-k8s).
- **How a change ships:** [application-pipeline-activity.png](architecture/application-pipeline-activity.png), in [CI/CD and GitOps](#cicd-and-gitops).

The request, deploy and log flows, the trust boundaries and the diagram sources are in [architecture/README.md](architecture/README.md).

The service is stateless, so there is no database.

## Requirements checklist

| Requirement | Where |
|---|---|
| **1** Managed Kubernetes, private registry, logs to object storage | EKS [`modules/eks`](infra/modules/eks), ECR [`modules/ecr`](infra/modules/ecr), S3 [`modules/log-archive`](infra/modules/log-archive) + [Fluent Bit](k8s/platform/fluent-bit.yaml) |
| **1** Secure and reliable, explained and drawn | [What was created and why](#what-was-created-and-why), [architecture/](architecture/README.md) |
| **2.1** `/` shows "Hello World"; BFF health route | [`page.tsx`](application/src/app/page.tsx), [`api/health/route.ts`](application/src/app/api/health/route.ts) |
| **2.2** Multi-stage, non-root, health check, version/SHA tags | [`Dockerfile`](application/Dockerfile), [`app-ci.yml`](.github/workflows/app-ci.yml) |
| **2.3** Runs locally with one compose file | [`docker-compose.yml`](docker-compose.yml) |
| **2.4** Manifests in `k8s/`, probes on the BFF, exposed to the internet | [`deployment.yaml`](k8s/deployment.yaml), [`ingress.yaml`](k8s/ingress.yaml) |
| **3.1** CI on every push to `main`: lint, build, image `:<sha>`, update Git | [`app-ci.yml`](.github/workflows/app-ci.yml) |
| **3.2** GitOps installed as code, watches `k8s/`, prune and self-heal | [`infra/gitops-bootstrap`](infra/gitops-bootstrap/main.tf), [`k8s/platform/`](k8s/platform) |
| **3.2** Health from the BFF endpoint; rollback by `git revert` of the bad commit | Readiness probes + [`smoke-test-job.yaml`](k8s/smoke-test-job.yaml); [Rollback](#gitops-argo-cd) |
| **3.3** PRs: format, validate, preview; apply after merge and approval | [`infra.yml`](.github/workflows/infra.yml) |
| **3.4** CI has no cluster credentials; no secrets in the repo | [CI/CD and GitOps](#cicd-and-gitops), [Secrets](#secrets-and-ci-configuration) |

### Bonus and advanced items

| Item | Status | Where |
|---|---|---|
| Well-structured, reusable infrastructure code | Built | 9 modules in [`infra/modules`](infra/modules), composed by [`infra/environments/prod`](infra/environments/prod) |
| Container vulnerability scanning | Built | Trivy gate on CRITICAL plus a CRITICAL/HIGH report in GitHub code scanning ([`app-ci.yml`](.github/workflows/app-ci.yml)); ECR scan on push |
| Deployment strategy and why | Rolling update | [Deployment strategy](#deployment-strategy-rolling-update) |
| Backup and restore procedures | Runbook | [backup-and-restore.md](architecture/enhancements/backup-and-restore.md), [room for improvement #15](architecture/enhancements/room-for-improvement.md#15-backup-and-restore-is-a-runbook-not-automation) |
| Chaos engineering tests | Test plan | [chaos-test-plan.md](architecture/enhancements/chaos-test-plan.md), [room for improvement #16](architecture/enhancements/room-for-improvement.md#16-chaos-testing-is-a-plan-not-automation) |

## Stacks and apply order

| # | Stack | State | What it creates |
|---|---|---|---|
| 1 | [`infra/bootstrap`](infra/bootstrap) | local | S3 bucket + KMS key for Terraform state (versioned, TLS-only, public access blocked, S3 native locking) |
| 2 | [`infra/environments/prod`](infra/environments/prod) | `prod/core.tfstate` | VPC, EKS, ECR, IAM, Route 53/ACM/WAF, log bucket, alarms |
| 3 | [`infra/gitops-bootstrap`](infra/gitops-bootstrap) | `prod/gitops-bootstrap.tfstate` | **Once, by an operator.** Installs Argo CD, its repository and cluster Secrets, the AppProjects and the root application |
| 4 | [`k8s/platform/`](k8s/platform) | Git | Argo CD ApplicationSets: AWS Load Balancer Controller, external-dns, metrics-server, Fluent Bit, Argo CD itself, and the service |
| 5 | [`k8s/`](k8s) | Git | The service's manifests, deployed and kept in sync by Argo CD |

- **Stacks 1 and 3 are applied by hand.** Stack 1 creates the state bucket. Stack 3 needs the private EKS API, so it runs from inside the VPC (VPN or SSM port-forward). It's re-run only to rebuild a cluster.
- **Stack 2:** after the first apply by an operator, which creates the CI roles, the [infra pipeline](#infrastructure-pipeline-githubworkflowsinfrayml) owns it.
- **Stacks 4 and 5** are Git: Argo CD applies every change.

Step-by-step commands are in [infra/README.md](infra/README.md).

## What was created and why

### Region and network: [`modules/network`](infra/modules/network)

#### Region: `us-east-1` (assumed)

Everything runs in one region, `us-east-1` (N. Virginia), across the AZs `us-east-1a`, `us-east-1b` and `us-east-1c`. This is an assumption, not a requirement, and nothing in the design depends on it:
- The WAF is attached to the regional ALB, not to CloudFront, so it doesn't need `us-east-1`.
- The ACM certificate is created in the same region as the ALB.

To use another region, change it everywhere it's set. The AZ names must belong to the new region:

| Where | Setting |
|---|---|
| [`infra/bootstrap/variables.tf`](infra/bootstrap/variables.tf) | `region` (state bucket) |
| [`infra/environments/prod/variables.tf`](infra/environments/prod/variables.tf) / `terraform.tfvars` | `region`, `azs` |
| `infra/environments/prod/backend.hcl` | `region` of the state bucket |
| [`infra/gitops-bootstrap/variables.tf`](infra/gitops-bootstrap/variables.tf) | `region` |
| GitHub Actions variable | `AWS_REGION` |

AZ names map to different physical zones in each AWS account. That doesn't matter inside one account. If you ever need to line up zones with another account, use AZ IDs (for example `use1-az1`).

#### Subnets

The VPC is `10.20.0.0/16` (`vpc_cidr`). It's a private range chosen so it's unlikely to overlap office, VPN or other VPC networks you may connect to later. Subnets are not listed by hand: the module derives them from the VPC CIDR with `cidrsubnet()` ([`main.tf`](infra/modules/network/main.tf)), giving one private and one public subnet per AZ:

| AZ | Private: nodes, pods, VPC endpoints | Public: ALB, NAT gateway |
|---|---|---|
| `us-east-1a` | `10.20.0.0/19` | `10.20.96.0/24` |
| `us-east-1b` | `10.20.32.0/19` | `10.20.97.0/24` |
| `us-east-1c` | `10.20.64.0/19` | `10.20.98.0/24` |
| Free (not allocated) | `10.20.99.0` – `10.20.127.255` and `10.20.128.0/17` | — |

- **Private, `/19`** (`cidrsubnet(vpc_cidr, 3, i)`): 8,187 usable addresses each, since AWS reserves 5 per subnet. Pods get VPC IPs from the VPC CNI. With prefix delegation each node takes `/28` blocks (16 addresses), so the subnets are sized for pods, node scaling and the extra pods during rolling updates, not just for nodes.
- **Public, `/24`** (`cidrsubnet(vpc_cidr, 8, 96 + i)`): 251 usable addresses each. They hold only the ALB and NAT gateway network interfaces. The ALB needs at least a `/27` with 8 free addresses per subnet.
- **Room to grow:** about half the VPC is unallocated, for extra tiers later (for example a database subnet group).
- **At most 3 AZs.** The module requires at least 2 AZs but doesn't check for a maximum. A 4th AZ would get the private subnet `10.20.96.0/19`, which overlaps the public `/24`s, so `terraform apply` fails with a CIDR conflict when it creates that subnet. Allowing more AZs would mean a new layout, which changes the CIDRs of existing subnets and so replaces them and the cluster. Three AZs is the normal production setup, so the layout stays as it is.
- **The NetworkPolicy uses the VPC CIDR.** The service's Argo CD ApplicationSet patches in the real value from the cluster Secret (see [Application runtime](#application-runtime-k8s)), so changing `vpc_cidr` needs no manifest change.

#### Routing and endpoints

- **One NAT gateway per AZ**, each private subnet routed to the NAT in its own AZ, so losing one AZ doesn't cut egress for the other two. Public subnets share one route table to the internet gateway.
- **VPC endpoints**: a gateway endpoint for S3 on the private route tables, plus interface endpoints for ECR API/DKR, STS, CloudWatch Logs, EKS Auth (Pod Identity) and Secrets Manager in the private subnets. The endpoints' security group allows HTTPS only, from the VPC CIDR. Image pulls, log uploads and credential exchange stay on the AWS network and don't depend on NAT.
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
- The Terraform pipeline's roles are covered in [CI/CD and GitOps](#cicd-and-gitops).
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

- **Route 53**: by default the stack looks up an existing public hosted zone (`create_hosted_zone = true` creates one and adds a CAA record restricting issuance to Amazon). **external-dns** (an Argo CD add-on) writes the alias record for the service hostname to the ALB, with `upsert-only` policy and TXT ownership records.
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

![Kubernetes components: namespaces, the service's resources, add-ons and Argo CD](architecture/k8s-components.png)

Environment values are kept out of the manifests:
- **The image** is the logical name `next-bff-service`. [`kustomization.yaml`](k8s/kustomization.yaml) maps it to the ECR repository and the commit-SHA tag that CI writes.
  - That committed line is the deploy record, so it does contain the real ECR URL, account ID included.
  - Until CI's first run it holds a placeholder account, so the first Argo CD sync shows `ImagePullBackOff` until the first image is pushed.
- **Everything else** (the Ingress hostname, certificate ARN, WAF ARN and the NetworkPolicy's VPC CIDR) is patched in by the service's Argo CD ApplicationSet from the cluster-Secret annotations (see [GitOps](#gitops-argo-cd)).
  - The CIDR patch starts with a JSON-patch `test` on the expected default, so if the manifest's layout changes, the sync fails loudly instead of patching the wrong rule.

Restricted Pod Security Standard on the namespace. Non-root UID 1001, read-only root filesystem, all capabilities dropped, seccomp `RuntimeDefault`. Startup, readiness and liveness probes on `/api/health`. Resource requests and limits. Pods are spread across zones and hosts. **HPA** scales between 3 and 12 replicas. A **PDB** keeps at least 2 pods up. Rolling updates use `maxUnavailable: 0` and a `preStop` delay so the ALB drains a pod before it stops. A **NetworkPolicy** allows ingress only from the VPC on port 3000.

### Deployment strategy: rolling update

**Choice:** a Kubernetes rolling update that never drops below the desired number of ready pods. It's configured in [`deployment.yaml`](k8s/deployment.yaml):

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 25%        # with 3 replicas: 1 extra pod at a time
    maxUnavailable: 0    # never fewer ready pods than desired
```

#### Why rolling update

| Need | How a rolling update meets it |
|---|---|
| **Zero downtime** | `maxUnavailable: 0`: an old pod is removed only after a new one passes its readiness probe. |
| **Low cost** | It needs one extra pod during a rollout. Blue-green needs a full second copy of the service for the whole switch. |
| **Simple** | It's built into Kubernetes, and Argo CD already shows its progress. No extra controller or CRDs to run, upgrade and secure. |
| **Fits the app** | The service is stateless, with no database and no schema migrations. Old and new versions can serve side by side for the minute a rollout takes. |
| **Fits the rollback model** | A rollback is a `git revert`, which is just another rolling update to the previous image. |

#### How a rollout runs

1. The deploy commit changes the image tag, and Argo CD applies it.
2. Kubernetes starts **one** new pod (25% of 3, rounded up).
3. The **startup probe** gives it up to 60 s to boot. Then the **readiness probe** on `/api/health` must pass before it receives traffic. The ALB health-checks it too, through `target-type: ip`.
4. Only then is an old pod terminated:
   - its `preStop` sleep (10 s) gives the AWS Load Balancer Controller time to deregister it from the ALB;
   - the ALB drains in-flight requests (`deregistration_delay` 30 s);
   - the process then gets SIGTERM, inside the 30 s grace period.
5. Repeat until every pod runs the new version. The **PDB** (`minAvailable: 2`) still protects the service if a node drain happens during the rollout.
6. After the sync, the PostSync **smoke test** calls `/api/health` through the Service.

**A bad release stops itself.** If new pods never become ready (crash, failed probe, missing image), the rollout stalls. The old pods keep serving, because none were removed. Argo CD shows the app as Progressing, then Degraded, and someone reverts the commit.

**What it doesn't catch:** a release that passes `/api/health` but fails real requests (5xx, slow pages). It reaches 100% of traffic, because there's no traffic analysis.

#### Alternatives considered

| Strategy | Why not now |
|---|---|
| **Recreate** | Stops every old pod before starting new ones, so every release is an outage. |
| **Blue-green** | Instant switch and instant switch-back, but it doubles capacity during each release. Switching ALB traffic needs Argo Rollouts or a second Service and Ingress. A bad release still hits 100% of users at once, just with a faster way back. |
| **Canary** | The best protection, since only a slice of traffic sees the new version first. But it needs Argo Rollouts, ALB weighted target groups, and metrics to judge the canary (5xx rate and latency). There are no ALB 5xx or latency alarms yet. A canary without analysis is just a slower rolling update. |

#### When to move to canary

Move to a canary once the service has real traffic and ALB metrics. The upgrade path is short:
1. Install Argo Rollouts with an ApplicationSet in `k8s/platform/`.
2. Replace the Deployment with a `Rollout`: `canary` with `trafficRouting.alb`, steps of 10% → 50% → 100%, with pauses.
3. Add an `AnalysisTemplate` that queries CloudWatch for ALB 5xx and p95 latency. A failed analysis aborts and shifts traffic back automatically.

This also closes items 3 and 4 in [room-for-improvement.md](architecture/enhancements/room-for-improvement.md).

#### Known gap: ALB pod readiness gate

The namespace doesn't have the label `elbv2.k8s.aws/pod-readiness-gate-inject: enabled`. Without it, Kubernetes counts a new pod as ready once its own probe passes, which can be a few seconds before the ALB marks the target healthy. With `maxUnavailable: 0` and three replicas, the service still has healthy targets throughout, but adding the label makes each step wait for the ALB as well. It's a one-line change to [`namespace.yaml`](k8s/namespace.yaml).

### Container image: [`application/Dockerfile`](application/Dockerfile)

A 3-stage build (deps → build → runner) using Next.js `standalone` output, so the runtime image contains only the traced production files. The `node:22-alpine` base is pinned by digest, and Dependabot updates it. It uses an npm cache mount, runs as **numeric** `USER 1001:1001` (required for `runAsNonRoot` to be verifiable), has a `HEALTHCHECK` on `/api/health`, and OCI labels for version and commit. Images are tagged `<version>` or `<git sha>` and pushed to ECR. Because the tags are immutable, overwriting `latest`-style tags isn't possible.

## CI/CD and GitOps

CI only builds and changes Git. Argo CD deploys whatever is in Git to the cluster.

![Application pipeline: PR checks, build and scan, push to ECR, Argo CD rollout, smoke test, and revert on failure](architecture/application-pipeline-activity.png)

The diagram follows one change from pull request to production:
1. PR checks run.
2. After the merge, CI builds and scans the image, pushes it to ECR and commits the new tag.
3. Argo CD rolls the new tag out and the smoke test checks it.
4. If the pods aren't healthy or the smoke test fails, the fix is to revert the bad commit, which runs the pipeline again.

**No pipeline can reach the cluster:**
- No workflow runs `kubectl`, Helm or a Kubernetes provider.
- No CI role has an EKS access entry, so even the Terraform apply role can't authenticate to the Kubernetes API.
- The CI roles call AWS APIs only: ECR push, and Terraform on the core stack.

### Application CI: [`.github/workflows/app-ci.yml`](.github/workflows/app-ci.yml)

Runs on every push to `main`, and every push ships an image and a deploy commit. Pull requests run only the first job.

1. **lint-build**: `npm ci`, `npm run lint` (ESLint with `eslint-config-next`), `npm run build`.
2. **image**: assumes `ci-image-publisher` through OIDC, then builds with Buildx and the GHA layer cache, passing the commit SHA as `VERSION`/`GIT_SHA`.
   - Trivy scans the local image. CRITICAL, fixable findings fail the job before anything is pushed. A second pass uploads CRITICAL and HIGH findings to GitHub code scanning (Security tab), even when the gate fails.
   - The image is pushed as `<ecr>/next-bff-service:<commit sha>`.
   - A re-run skips the build if that tag already exists, because tags are immutable.
3. **update-manifests** ([`update-image-tag.sh`](.github/scripts/update-image-tag.sh)): runs `kustomize edit set image next-bff-service=<ecr>:<sha>` in `k8s/` and pushes a `deploy(next-bff-service): <sha>` commit to `main` using the workflow's `GITHUB_TOKEN`.
   - That commit is the deploy trigger.
   - It can't loop: GitHub doesn't start workflows for commits pushed with `GITHUB_TOKEN`.
   - **Safe ordering without queues:**
     - Every push to `main` gets its own run, so no push's app change can be dropped by GitHub cancelling a queued run.
     - `git push` itself is the lock: it is rejected if `main` moved, and the script then re-reads `main` and retries.
     - Before each attempt it checks that the deployed SHA is an ancestor of its own (`git merge-base --is-ancestor`), so a slow, older build never replaces a newer deploy.

All third-party actions are pinned to commit SHAs, and Dependabot keeps them current. Every job starts from `contents: read` and asks only for what it needs.

### GitOps: Argo CD

**Bootstrap, run once** ([`infra/gitops-bootstrap`](infra/gitops-bootstrap/main.tf)). An operator applies it from inside the VPC. It:
1. **Installs Argo CD** from the pinned `argo-cd` Helm chart, using [`k8s/platform/values/argo-cd.yaml`](k8s/platform/values/argo-cd.yaml). The install is HA: Redis HA, plus two replicas of the server, repo-server and ApplicationSet controller.
   - The server is ClusterIP only, with no public UI. Operators use `kubectl port-forward` until SSO is configured.
   - Terraform then ignores the release. Argo CD manages its own chart from the same values file, so upgrading Argo CD is a commit.
2. **Creates the repository Secret** with a read-only GitHub deploy key, because the repo is private.
   - The key is stored in Secrets Manager (`prod/argocd/repo-deploy-key`; the core stack creates the empty secret).
   - It never appears in Git or in Helm values.
3. **Creates the in-cluster Secret** with the core stack outputs as annotations: region, cluster name, VPC ID and CIDR, log bucket, hosted zone, hostname, certificate ARN, WAF ARN. This is the GitOps-bridge pattern.
   - The ApplicationSets read those values through the cluster generator.
   - The manifests hardcode no hostnames, ARNs or VPC ranges.
   - The one environment value in Git is deliberate: the image reference that CI commits to `kustomization.yaml` (`<account>.dkr.ecr.<region>.amazonaws.com/next-bff-service:<sha>`). That line *is* the deploy record.
4. **Creates three AppProjects** as security boundaries:
   - `bootstrap` may only create ApplicationSets in `argocd`.
   - `platform` holds the add-ons, in `argocd`, `kube-system` and `logging` only.
   - `next-bff` limits the source to this repository and the destination to the `next-bff` namespace. The Namespace is the only cluster-scoped resource it allows.
5. **Creates the root application** (app-of-apps), which syncs [`k8s/platform/`](k8s/platform).

**Everything else is Git** ([`k8s/platform/`](k8s/platform)): one ApplicationSet each for:
- Argo CD itself
- the AWS Load Balancer Controller
- external-dns
- metrics-server
- Fluent Bit
- the service

Each has automated sync with prune and self-heal, and pinned chart versions. Failed syncs retry with backoff, for example while the load balancer controller's webhook starts.

**The service** ([`next-bff-service.yaml`](k8s/platform/next-bff-service.yaml)):
- **Watches `k8s/`:** it tracks `main`, path `k8s`, with `syncPolicy.automated { prune: true, selfHeal: true }`.
  - Every committed change is applied, deleted manifests are pruned, and manual edits in the cluster are reverted.
  - The only ignored drift is `Deployment.spec.replicas`, which the HPA owns (`RespectIgnoreDifferences=true`).
- **Health from the BFF endpoint:**
  - **Application health:** comes from its resources. The Deployment is only Healthy once its pods pass readiness probes on `/api/health`, and the ALB target group checks the same path.
  - **Sync result:** after each sync, a `PostSync` hook Job ([`k8s/smoke-test-job.yaml`](k8s/smoke-test-job.yaml)) calls `http://next-bff-service:3000/api/health` through the Service. Anything other than a 2xx marks the sync operation Failed, and the retry policy tries again.
- **Rollback:** revert the commit that broke the app, and push.
  ```bash
  git revert <bad-app-commit> && git push
  ```
  - Like every push, the revert goes through CI: the reverted code is built, tagged with the revert's SHA and deployed. Argo CD syncs it within its 3-minute poll.
  - Reverting only the deploy commit is not enough on its own: that revert is also a push, so CI would rebuild the current (broken) code and deploy it again.
- **Emergency rollback without a build:** revert the deploy commit and put `[skip ci]` in the message, so no workflow runs and Argo CD syncs the previous tag.
  ```bash
  git revert --no-commit <deploy-commit>
  git commit -m "Roll back next-bff-service to <previous sha> [skip ci]"
  git push
  ```
  - Immutable tags guarantee it's the same image as before. ECR keeps the last 50 tagged images, which sets how far back this can go.
  - The broken code is still on `main`: the next push rebuilds and redeploys it, so revert or fix the app commit next.
  - Trade-offs are listed in [architecture/enhancements/room-for-improvement.md](architecture/enhancements/room-for-improvement.md).
- **Deleting an ApplicationSet or Application:** every ApplicationSet sets `preserveResourcesOnDeletion: true`. Without it, Argo CD adds a resources finalizer to generated Applications, so deleting an ApplicationSet file from Git, or the cluster Secret no longer matching its selector, would delete the running service. With it, removal leaves workloads running.

### Infrastructure pipeline: [`.github/workflows/infra.yml`](.github/workflows/infra.yml)

| Event | Jobs |
|---|---|
| Pull request touching `infra/` | `terraform fmt -check`, `init -backend=false` + `validate` on every stack, `tflint` (recommended + AWS rulesets). Then `plan` of the core stack with the read-only plan role (`-lock=false`), posted as a sticky PR comment. |
| Push to `main` (after merge) | `apply` in the GitHub `production` environment, which waits for a required reviewer. It re-plans and applies the core stack. |

- **What it manages:** the core stack only, all through AWS APIs. Jobs run on GitHub-hosted runners. The gitops-bootstrap stack is validated here, but applied once by an operator: it's the only Terraform that talks to Kubernetes.
- **Roles** ([`modules/ci-terraform`](infra/modules/ci-terraform)):
  - **`ci-terraform-plan`** is trusted only for `repo:<repo>:pull_request`. It has `ReadOnlyAccess`, plus read access on **one** state object (`prod/core.tfstate`) and the state KMS key.
    - An explicit deny blocks every other S3 object read. Application logs stay out of reach, and so does the gitops-bootstrap state, which holds the Argo CD deploy key.
    - PRs from forks get no OIDC token, so they never reach it.
  - **`ci-terraform-apply`** is trusted only for `repo:<repo>:environment:production`, so GitHub won't issue the token until the environment's reviewers approve.
  - Neither role has an EKS access entry.
- **Bootstrapping:** the first core apply is run by an operator, because it creates these roles. From then on the pipeline owns the core stack.

### Secrets and CI configuration

There are no secrets in the repository; gitleaks scans every push and PR ([`security.yml`](.github/workflows/security.yml)). Everything environment-specific lives in the GitHub secret store:

| Name | Kind | Value |
|---|---|---|
| `AWS_REGION`, `ECR_REPOSITORY` | variable | e.g. `us-east-1`, `next-bff-service` |
| `AWS_IMAGE_PUBLISHER_ROLE_ARN` | variable | core output `ci_image_publisher_role_arn` |
| `AWS_TERRAFORM_PLAN_ROLE_ARN`, `AWS_TERRAFORM_APPLY_ROLE_ARN` | variable | core outputs `terraform_plan_role_arn`, `terraform_apply_role_arn` |
| `TF_STATE_BUCKET`, `TF_STATE_KMS_KEY_ARN` | variable | bootstrap outputs |
| `PROD_TFVARS` | secret | contents of `infra/environments/prod/terraform.tfvars` |

Role ARNs are not secrets, but keeping them in variables keeps account IDs out of the repo. The Argo CD deploy key and application secrets live in AWS Secrets Manager.

## Production assumptions and follow-ups

Known gaps against the requirements, and trade-offs of following them exactly, are in [architecture/enhancements/room-for-improvement.md](architecture/enhancements/room-for-improvement.md).

- **Region / account**: one region, `us-east-1`, is assumed (see [Region](#region-us-east-1-assumed) for how to change it), with no multi-region failover. Run production in a dedicated account and keep non-production in separate accounts with their own `environments/<env>` directory.
- **Reaching the private API**: only humans need it, for the one-time `infra/gitops-bootstrap` and for `kubectl` debugging. They run from inside the VPC (VPN or SSM port-forward). Alternatively, set `eks_endpoint_public_access` to an office/VPN CIDR.
- **Node autoscaling**: the node group has fixed min/max values. Add Karpenter or Cluster Autoscaler (with its own Pod Identity role) before relying on the HPA ceiling.
- **ALB alarms and access logs**: the ALB is created by the controller, so 5xx/latency alarms and ALB access logs (these need an SSE-S3 bucket) are added once its name is known.
- **Argo CD access**: add SSO (Dex or OIDC against the identity provider) and RBAC, then disable the local admin. Add a GitHub webhook to cut the 3-minute poll, and Argo CD Notifications (Slack or SNS) for sync failures.
- **Progressive delivery**: Argo Rollouts with an ALB canary and analysis on 5xx rate would let failed releases roll back automatically, rather than through a revert commit. See [Deployment strategy](#deployment-strategy-rolling-update) for why the rolling update comes first.
- **Supply chain**: sign images with cosign in CI, and enforce signatures in the cluster (e.g. Kyverno).
- **Apply role scope**: `ci-terraform-apply` has `AdministratorAccess`. Replace it with a scoped policy or a permissions boundary once the set of resource types settles. Add an SCP or boundary that denies `eks:CreateAccessEntry` and `eks:AssociateAccessPolicy` to CI roles, so they can't grant themselves cluster access.
- **Branch protection**: require PRs and status checks on `main`, and allow only the Actions bot to push deploy commits (a ruleset bypass).
