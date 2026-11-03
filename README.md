# devops-challenge

A stateless Next.js service (`next-bff-service`) running on Amazon EKS and delivered with GitOps.
- `infra/` holds the Terraform: VPC, EKS, ECR, IAM, Route 53/ACM/WAF, S3 log archive and CI identities, plus the one-time Argo CD bootstrap.
- `k8s/` holds the service manifests. `k8s/platform/` holds the Argo CD ApplicationSets for the add-ons and the service. Argo CD deploys both.
- `.github/workflows/` holds the CI pipelines.

**Where each requirement is met:** [ARCHITECTURE.md § Requirements checklist](ARCHITECTURE.md#requirements-checklist).

**Prerequisites:** Docker with Compose for the local run. For the infrastructure: Terraform ≥ 1.10, the AWS CLI and kubectl (see [infra/README.md](infra/README.md)).

## Layout

```
devops-challenge/
├── infra/                 # Terraform: bootstrap, environments/prod, gitops-bootstrap, modules
├── application/           # Next.js app + Dockerfile
├── k8s/                   # Service manifests (kustomize); platform/ = Argo CD ApplicationSets
├── .github/workflows/     # CI: app-ci, infra, security
├── docker-compose.yml
├── .env.example
├── architecture/          # diagrams, repo-structure.pdf, enhancements/ (room for improvement, backup runbook, chaos plan)
├── README.md
└── ARCHITECTURE.md
```

Architecture overview: [ARCHITECTURE.md](ARCHITECTURE.md). Provisioning steps: [infra/README.md](infra/README.md). Diagrams: [architecture/README.md](architecture/README.md).

## Local run

```bash
docker compose up --build
```

No `.env` is needed: every setting has a default (image `local/next-bff-service:0.1.0`, port 3000). The `.env` file is only for pushing to ECR (below).

- App: http://localhost:3000
- Health: http://localhost:3000/api/health

The image runs as user `nextjs` (uid 1001). The Dockerfile `HEALTHCHECK` calls `/api/health`.

## Build, tag, and push to ECR (Part 2.2)

Images are named `${IMAGE_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}`. Use a version or commit SHA, not only `latest`.

```bash
cp .env.example .env
# IMAGE_REGISTRY=<account>.dkr.ecr.<region>.amazonaws.com
# IMAGE_NAME=next-bff-service
# IMAGE_TAG=$(git rev-parse --short HEAD)   # or 0.1.0 — ECR tags are immutable

set -a && source .env && set +a

aws ecr get-login-password --region <region> \
  | docker login --username AWS --password-stdin "$IMAGE_REGISTRY"

docker compose build
docker push "${IMAGE_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
```

## CI/CD (Part 3)

```
push to main ─▶ app-ci: lint · build ─▶ Trivy · push ECR :<sha> ─▶ commit k8s/kustomization.yaml newTag=<sha>
                                                                │
                             Argo CD (in cluster) polls main ◀──┘ ─▶ sync k8s/ (prune, self-heal) ─▶ PostSync GET /api/health
```

- **Deploy:** merge to `main`. The pipeline commits the image tag, and Argo CD applies it within about 3 minutes.
- **Roll back:** revert the commit that broke the app. CI builds the reverted code and Argo CD deploys it.

  ```bash
  git revert <bad-app-commit> && git push
  ```

  For an emergency rollback without a build, see [Rollback](ARCHITECTURE.md#gitops-argo-cd).
- **Infrastructure:**
  - Open a PR that touches `infra/`: format, validate and tflint run on every stack, and the core-stack plan is posted as a PR comment.
  - After the merge, approve the `production` environment deployment to apply.
- **Secrets:** none are committed. CI configuration lives in GitHub Actions variables and secrets (listed in [ARCHITECTURE.md](ARCHITECTURE.md#secrets-and-ci-configuration)). The Argo CD deploy key and app secrets live in AWS Secrets Manager.

The manual ECR push above is only needed before CI is set up.
