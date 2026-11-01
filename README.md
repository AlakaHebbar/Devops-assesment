# devops-challenge

A stateless Next.js service (`next-bff-service`) running on Amazon EKS and delivered with GitOps.
- `infra/` holds the Terraform: VPC, EKS, ECR, IAM, Route 53/ACM/WAF, S3 log archive and CI identities, plus the one-time Argo CD bootstrap.
- `k8s/` holds the service manifests. `k8s/platform/` holds the Argo CD ApplicationSets for the add-ons and the service. Argo CD deploys both.
- `.github/workflows/` holds the CI pipelines.

## Layout

```
devops-challenge/
├── infra/                 # Terraform: bootstrap, environments/prod, gitops-bootstrap, modules
├── application/           # Next.js app + Dockerfile
├── k8s/                   # Service manifests (kustomize); platform/ = Argo CD ApplicationSets
├── .github/workflows/     # CI: app-ci, infra, security
├── docker-compose.yml
├── .env.example
├── architecture/          # design document: Mermaid source + exported SVG/PNG
├── README.md
└── ARCHITECTURE.md
```

Architecture overview: [ARCHITECTURE.md](ARCHITECTURE.md). Provisioning steps: [infra/README.md](infra/README.md). Diagram: [architecture/README.md](architecture/README.md).

## Local run

```bash
cp .env.example .env
# set IMAGE_REGISTRY, IMAGE_NAME, and IMAGE_TAG (version or git SHA, not only latest)
docker compose up --build
```

- App: http://localhost:3000
- Health: http://localhost:3000/api/health

The image runs as user `nextjs` (uid 1001). The Dockerfile `HEALTHCHECK` calls `/api/health`.

## Build, tag, and push to ECR (Part 1)

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
push to main ─▶ app-ci: lint · build ─▶ (if application/ changed) Trivy · push ECR :<sha> ─▶ commit k8s/kustomization.yaml newTag=<sha>
                                                                          │
                                       Argo CD (in cluster) polls main ◀──┘ ─▶ sync k8s/ (prune, self-heal) ─▶ PostSync GET /api/health
```

- **Deploy:** merge to `main`. The pipeline commits the image tag, and Argo CD applies it within about 3 minutes.
- **Roll back:**

  ```bash
  git revert <deploy-commit> && git push
  ```

  Argo CD syncs the previous image.
- **Infrastructure:**
  - Open a PR that touches `infra/`, and the plans are posted as comments.
  - After the merge, approve the `production` environment deployment to apply.
- **Secrets:** none are committed. CI configuration lives in GitHub Actions variables and secrets (listed in [ARCHITECTURE.md](ARCHITECTURE.md#secrets-and-ci-configuration)). The Argo CD deploy key and app secrets live in AWS Secrets Manager.

The manual ECR push above is only needed before CI is set up.
