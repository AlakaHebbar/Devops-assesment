# devops-challenge

Stateless Next.js service (`next-bff-service`) running on Amazon EKS. `infra/` holds the Terraform (VPC, EKS, ECR, IAM, Route 53/ACM/WAF, S3 log archive); `k8s/` holds the service manifests. `.github/workflows/` (CI) and GitOps come in a later part.

## Layout

```
devops-challenge/
├── infra/                 # Terraform: bootstrap, environments/prod, platform, modules
├── application/           # Next.js app + Dockerfile
├── k8s/                   # Kubernetes manifests (kustomize)
├── .github/workflows/     # CI (later)
├── docker-compose.yml
├── .env.example
├── architecture/          # diagram source
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
