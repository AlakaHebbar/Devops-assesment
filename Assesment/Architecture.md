# AWS production architecture — Next.js on Amazon EKS

## Purpose

This document describes an AWS production design for the Part 2 Next.js service. The detailed architecture diagram, AWS component names, and request/data flows are in [architecture/README.md](architecture/README.md), with standalone Mermaid source at [architecture/architecture.mmd](architecture/architecture.mmd).

The service is stateless: Amazon EKS runs multiple Next.js replicas on private EC2 managed node groups. The application writes structured logs to standard output; Fluent Bit ships them to a private, encrypted Amazon S3 bucket. No database or persistent application storage is assumed because neither is specified in the requirements.

## What the architecture provides

- **Private-by-default network:** a multi-AZ Amazon VPC has public subnets for the internet-facing Application Load Balancer and private subnets for EKS nodes and pods. NAT Gateways provide controlled outbound access; VPC endpoints keep AWS service traffic on private network paths where supported.
- **Protected ingress:** Amazon Route 53 points to an Application Load Balancer (ALB) provisioned by AWS Load Balancer Controller. AWS WAFv2 protects the ALB and AWS Certificate Manager (ACM) supplies the TLS certificate.
- **Resilient application runtime:** multiple replicas spread across zones, readiness/liveness/startup probes, resource requests/limits, autoscaling, disruption budgets, and rolling deployments reduce the impact of failures and releases.
- **Private image distribution:** CI builds, tests, scans, and signs immutable images, then pushes them to Amazon ECR using GitHub Actions OIDC and a narrowly scoped IAM role. EKS nodes pull images using their IAM role; no registry credentials are stored in manifests.
- **Least-privilege secrets and storage access:** EKS Pod Identity (or IRSA) gives the application and log collector separate IAM roles. The application reads only its runtime secrets from AWS Secrets Manager; the collector alone writes to the log bucket.
- **Durable logs and operations:** Fluent Bit buffers/retries delivery to a private S3 bucket protected by S3 Block Public Access, SSE-KMS, lifecycle/retention rules, and restrictive bucket policy. EKS control-plane audit logs and platform/application metrics go to Amazon CloudWatch for monitoring and alarms.

## AWS components at a glance

| Layer | AWS components |
|---|---|
| Network | Amazon VPC, public ALB subnets, private EKS subnets across 3 Availability Zones, route tables, security groups, NAT Gateway per AZ, VPC endpoints |
| Kubernetes | Regional Amazon EKS control plane with private API endpoint, EC2 managed node groups, EKS Pod Identity, EKS control-plane logging |
| Ingress / TLS | Amazon Route 53, AWS WAFv2, internet-facing Application Load Balancer, AWS Load Balancer Controller, AWS Certificate Manager |
| Image delivery | GitHub Actions OIDC, IAM publishing role, Amazon ECR, EKS node IAM role for image pulls |
| Workload secrets | AWS Secrets Manager, AWS KMS, EKS Pod Identity (or IRSA), Secrets Store CSI Driver/provider if mounted files are needed |
| Log archive | Fluent Bit DaemonSet, dedicated Pod Identity role, Amazon S3 with Block Public Access, SSE-KMS, versioning and lifecycle/retention policy |
| Monitoring | Amazon CloudWatch Logs, Container Insights/CloudWatch metrics, CloudWatch alarms and SNS notifications |
| IaC state | Terraform state in a dedicated encrypted S3 bucket with versioning and least-privilege access |

The design uses AWS-managed control plane, network edge, registry, secrets, monitoring, and storage services. Worker nodes and pods are not directly internet-addressable. Deploy production resources in a dedicated AWS account and region; use separate accounts for non-production environments.

## Implementation sequence

1. Establish a dedicated AWS account, region, IAM Identity Center access, tagging/budget policies, and Terraform remote state in encrypted, versioned S3.
2. Create an Amazon VPC spanning at least three Availability Zones. Put the ALB in public subnets; EKS nodes and pods go in private subnets. Add per-AZ NAT Gateways, routes, security groups, and VPC endpoints (ECR API/Docker, S3, STS, Secrets Manager, and CloudWatch Logs as needed).
3. Provision regional Amazon EKS with a private Kubernetes API endpoint, managed EC2 node groups in private subnets, encrypted Kubernetes secrets, control-plane audit/authenticator/API logs, and supported upgrade settings.
4. Create Amazon ECR repositories with immutable tags and lifecycle policies. Set up GitHub Actions OIDC to assume a scoped IAM role for publishing; grant EKS node roles only the ECR pull permissions they need.
5. Install AWS Load Balancer Controller with its own Pod Identity role. Create an ALB-backed Ingress, associate AWS WAFv2, attach an ACM certificate, and publish a Route 53 alias record.
6. Deploy Next.js using a Kubernetes Deployment and internal Service. Configure probes, non-root security context, resource requests/limits, topology spread, HPA, PodDisruptionBudget, and rolling update strategy.
7. Give the app a dedicated EKS Pod Identity role for required Secrets Manager reads; use KMS encryption and rotation. Do not store AWS keys or secret values in Git.
8. Install Fluent Bit as a DaemonSet with a separate Pod Identity role limited to writing to the designated S3 prefix. Enable S3 Block Public Access, SSE-KMS, versioning, lifecycle/retention, and delivery-failure alerts.
9. Send EKS control-plane logs and workload/platform metrics to CloudWatch. Add CloudWatch dashboards/alarms and SNS notifications; test deployment rollback, AZ failure behavior, backup/restore, and incident runbooks.

Infrastructure code can be added incrementally in this order. Terraform modules can be organized around the VPC, EKS, ECR/CI identity, ALB/WAF/DNS, IAM/secrets, S3 logging, and CloudWatch resources.

## Production assumptions and follow-up decisions

- Confirm the AWS region, account boundaries, and Terraform state ownership before provisioning.
- Confirm the service's port, health endpoints, CPU/memory profile, expected traffic, log volume, and retention/compliance requirements.
- Add a managed database or durable application storage only if the service actually needs it; do not treat container filesystems as persistent.
- Decide whether Argo CD or Flux is the GitOps reconciler. The reference flow uses an in-cluster GitOps controller so CI does not need standing cluster-admin credentials.
