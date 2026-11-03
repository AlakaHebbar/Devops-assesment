# Room for improvement

The pipelines follow requirements 3.1–3.4 as written. This page lists what that costs, where the requirements are met with a caveat, and what would improve each point.

Each item has three parts:
- **Today:** how it works now.
- **Risk:** what can go wrong.
- **Improvement:** what would fix it.

| # | Area | Requirement | Item |
|---|---|---|---|
| 1 | CI | 3.1 | [A new image and deploy on every push](#1-a-new-image-and-deploy-on-every-push) |
| 2 | CD | 3.2 | [Rollback means a rebuild](#2-rollback-means-a-rebuild) |
| 3 | CD | 3.2 | [No automatic rollback](#3-no-automatic-rollback) |
| 4 | CD | 3.2 | [Health is indirect](#4-health-is-indirect) |
| 5 | CD | 3.2 | [Only files listed in kustomization.yaml are applied](#5-only-files-listed-in-kustomizationyaml-are-applied) |
| 6 | CI | 3.1, 3.4 | [CI pushes straight to main](#6-ci-pushes-straight-to-main) |
| 7 | IaC | 3.3 | [Not every stack is previewed](#7-not-every-stack-is-previewed) |
| 8 | IaC | 3.3 | [Lock-free PR plans, and apply re-plans](#8-lock-free-pr-plans-and-apply-re-plans) |
| 9 | IaC | 3.3 | [Apply needs merge and approval](#9-apply-needs-merge-and-approval) |
| 10 | Security | 3.4 | [Other things that change the cluster](#10-other-things-that-change-the-cluster) |
| 11 | Security | 3.4 | [The Terraform apply role is too broad](#11-the-terraform-apply-role-is-too-broad) |
| 12 | Security | 3.4 | [Not every secret is in the CI secret store](#12-not-every-secret-is-in-the-ci-secret-store) |
| 13 | Security | — | [The account ID is in Git](#13-the-account-id-is-in-git) |
| 14 | CD | — | [Argo CD polls Git, and its UI has no SSO](#14-argo-cd-polls-git-and-its-ui-has-no-sso) |
| 15 | Reliability | — | [Backup and restore is a runbook, not automation](#15-backup-and-restore-is-a-runbook-not-automation) |
| 16 | Reliability | — | [Chaos testing is a plan, not automation](#16-chaos-testing-is-a-plan-not-automation) |

## 1. A new image and deploy on every push

**Today:** [`app-ci.yml`](../../.github/workflows/app-ci.yml) builds, scans and pushes an image, then commits its tag, on every push to `main`. Pushes that change only docs or `k8s/` are included.

**Risk:**
- A rolling restart with identical code on every docs change. Each one is a small availability risk and adds noise to the deploy history.
- More images in ECR. The lifecycle policy keeps the last 50 tagged images, so the window you can roll back into covers fewer real releases.
- More CI minutes and Trivy runs.

**Improvement:** skip the image and deploy jobs when nothing under `application/` changed (a `paths` filter, or a diff job like the one this repo used to have). Alternatively, build by content: tag with the commit SHA, but reuse the existing image digest when the build context hash is unchanged.

## 2. Rollback means a rebuild

**Today:** rollback is `git revert <bad app commit>`. Because every push deploys, a revert of the *deploy* commit on its own would be rebuilt from the current, broken code and deployed again. So the main path rebuilds the reverted code. The emergency path is to revert the deploy commit with `[skip ci]` in the message.

**Risk:**
- **Main path:** a rollback takes a full pipeline run (build, scan, push, then the Argo CD poll). It also produces a new image rather than the exact bytes that ran before.
- **Emergency path:** it depends on someone remembering `[skip ci]`; without it, the bad version comes back. It also skips gitleaks for that push. And the broken code is still on `main`, so the next push redeploys it unless the app commit is reverted or fixed too.

**Improvement:** a dedicated rollback workflow (`workflow_dispatch`, input: target SHA) that checks the image exists in ECR and commits that tag. It has no build, no flags to remember, and leaves an audit trail. Item 3 removes most manual rollbacks altogether.

## 3. No automatic rollback

**Today:** a failing PostSync smoke test marks the *sync* as failed and Argo CD retries, but the bad version stays deployed. A person has to revert.

**Risk:** a release that passes readiness but fails real traffic (5xx, latency) stays live until someone notices.

**Improvement:** Argo Rollouts with an ALB canary, and an AnalysisTemplate on the 5xx rate and latency, aborts and rolls back automatically. Add Argo CD Notifications (Slack or SNS) for failed syncs and degraded health.

## 4. Health is indirect

**Today:** Argo CD derives application health from its resources. The Deployment is Healthy only when the pods' readiness probes on `/api/health` pass. The smoke test calls the same endpoint, but it affects the sync result, not the health status.

**Risk:**
- `/api/health` returns 200 whenever the process is up. It doesn't check dependencies, so "Healthy" means "the process responds".
- A smoke-test failure doesn't show as Degraded in the Argo CD UI.

**Improvement:**
- Split the endpoint into liveness (process up) and readiness (dependencies reachable).
- Add a custom Argo CD health check (Lua) or a Rollouts analysis, so a failed smoke test or error-rate breach shows as Degraded.

## 5. Only files listed in kustomization.yaml are applied

**Today:** Argo CD renders `k8s/` with Kustomize. A new manifest in `k8s/` is applied only once it's listed under `resources:` in [`kustomization.yaml`](../../k8s/kustomization.yaml).

**Risk:** someone adds a file and expects it to deploy. Nothing happens, and nothing reports an error.

**Improvement:** a CI check that fails when a `*.yaml` in `k8s/` (outside `platform/`) isn't listed in `kustomization.yaml`. Also run `kustomize build k8s | kubeconform` on PRs.

## 6. CI pushes straight to main

**Today:** [`update-image-tag.sh`](../../.github/scripts/update-image-tag.sh) pushes the deploy commit to `main` with `GITHUB_TOKEN`. `main` has no branch protection.

**Risk:**
- Anyone with write access can push to `main`, which deploys straight to production.
- Turning on "require pull requests" without a bypass for the bot would break every deploy.

**Improvement:** a ruleset that requires PRs and status checks on `main`, with a bypass for the GitHub Actions app only. Alternatively, CI opens an auto-merging PR for each tag bump (3.1 allows either). Require CODEOWNERS review for `k8s/` and `infra/`.

## 7. Not every stack is previewed

**Today:** PRs run fmt, validate and tflint on all three stacks, but `plan` runs only on the core stack ([`infra.yml`](../../.github/workflows/infra.yml)).
- `infra/bootstrap` uses local state held by an administrator.
- `infra/gitops-bootstrap` uses the Kubernetes and Helm providers, so planning it would need cluster credentials, which 3.4 forbids.

**Risk:** a change to either stack is reviewed without a plan. Both are also applied by hand by an operator, and nothing technically stops an operator applying an unmerged branch.

**Improvement:**
- Move `bootstrap` state into the bucket and plan it with the read-only role.
- Keep `gitops-bootstrap` small and stable, and apply it only from a tagged commit on `main`, following a runbook.
- An alternative is an in-VPC runner (Atlantis, or a self-hosted runner with its own access entry) that plans it. That runner would hold cluster access, so it would be a deliberate exception to 3.4.

## 8. Lock-free PR plans, and apply re-plans

**Today:** the read-only plan role can't write the state lock, so PR plans run with `-lock=false`. After approval, `apply` re-plans against current state and applies that new plan.

**Risk:**
- A PR plan taken while an apply is running can read in-between state and show a wrong diff.
- The reviewer approves a plan they didn't see byte for byte. If state drifted after the PR, the apply can differ from the PR comment.

**Improvement:**
- Save the PR plan as an artifact and apply exactly that file, failing if state has moved since (the stale-plan check).
- Or show the re-plan in the job summary and require the environment approval *after* it, using a two-job plan → approve → apply.

## 9. Apply needs merge and approval

**Today:** 3.3 says "apply only after merge **or** manual approval". The `apply` job requires both: it runs only on `main` after merge, then waits for a required reviewer on the `production` environment.

**Risk:** none for safety; this is stricter than required. The cost is speed: every infra change needs a second person after the merge.

**Improvement:** keep it for production. For non-production environments, apply on merge without the reviewer step.

## 10. Other things that change the cluster

**Today:** CI has no cluster credentials, and Argo CD applies everything from Git. Two other paths still change what runs in the cluster:
- **`infra/gitops-bootstrap`**, run once by an operator. It installs Argo CD and creates the repository and cluster Secrets.
- **The core Terraform stack**, through AWS APIs. It manages EKS add-ons (vpc-cni, CoreDNS, kube-proxy, Pod Identity agent, CloudWatch Observability), access entries and Pod Identity associations.

**Risk:** these changes don't appear in `k8s/`, and Argo CD neither reconciles nor reverts them.

**Improvement:**
- Document both as the deliberate boundary: AWS-managed add-ons belong to Terraform, and everything else belongs to Argo CD.
- Optionally move CoreDNS and CloudWatch Observability into Argo CD as Helm charts, so only the networking add-ons stay in Terraform.

## 11. The Terraform apply role is too broad

**Today:** `ci-terraform-apply` has `AdministratorAccess`. It has no EKS access entry, but its IAM rights would let it create one.

**Risk:** a compromised apply job could grant itself cluster access, getting around 3.4.

**Improvement:**
- Replace `AdministratorAccess` with a scoped policy plus a permissions boundary.
- Add an SCP that denies `eks:CreateAccessEntry` and `eks:AssociateAccessPolicy` to CI roles.

## 12. Not every secret is in the CI secret store

**Today:** the CI's own configuration lives in GitHub: `PROD_TFVARS` is a secret, and the role ARNs and bucket names are variables. The Argo CD repository deploy key lives in AWS Secrets Manager, because CI never uses it; only the bootstrap reads it.

**Risk:** a strict reading of "secrets live in the CI tool's secret store" isn't met for that key. Nothing is in Git: gitleaks runs on every push, and `.gitignore` covers key, tfvars and backend files.

**Improvement:** state the rule as "no secrets in Git; CI secrets in GitHub, runtime secrets in Secrets Manager". For runtime secrets, add External Secrets Operator.

## 13. The account ID is in Git

**Today:** the cluster-Secret annotations keep ARNs and hostnames out of the manifests. However, `kustomization.yaml` holds the full ECR image reference (`<account>.dkr.ecr.<region>.amazonaws.com/...`), so the account ID is committed after the first deploy.

**Risk:** an account ID isn't a secret, but it contradicts the "no account IDs in Git" goal and helps an attacker with reconnaissance.

**Improvement:** commit only `newTag`, and inject `newName` through the ApplicationSet from a cluster-Secret annotation, the same way the hostname is injected.

## 14. Argo CD polls Git, and its UI has no SSO

**Today:** Argo CD polls `main` every 3 minutes. The UI is ClusterIP only, has no SSO, and is reached with `kubectl port-forward`.

**Risk:**
- Up to 3 minutes between the deploy commit and the sync, which also slows rollbacks.
- The local admin account is the only way into the UI.

**Improvement:**
- A GitHub webhook to `argocd-server` (behind the WAF) for near-instant syncs.
- Dex or OIDC SSO with RBAC, then disable the local admin.

## 15. Backup and restore is a runbook, not automation

**Today:** the service is stateless, so recovery means rebuilding from Git and the Terraform state. [backup-and-restore.md](backup-and-restore.md) lists what can be lost, how each piece is protected (state bucket versioning, `prevent_destroy`, immutable ECR tags, Secrets Manager and KMS recovery windows), and the commands to recover from nine scenarios, from a bad release to losing the cluster.

**Risk:**
- Every copy lives in the same account and region. A compromised admin or a region outage takes the state bucket with it.
- The `infra/bootstrap` state is a local file.
- The procedures haven't been drilled, so the 1-hour rebuild estimate is unproven.

**Improvement:**
- Replicate the state bucket to a separate backup account with S3 Cross-Region Replication and Object Lock.
- Move the bootstrap state into the bucket (see item 7).
- Run the drills listed in the runbook and record the real recovery time.
- Add Velero, or AWS Backup for a database, once anything stateful appears.

## 16. Chaos testing is a plan, not automation

**Today:** [chaos-test-plan.md](chaos-test-plan.md) defines ten experiments (pod, node and AZ loss, CPU load, a bad release, Argo CD and CoreDNS outages), each with the protection it tests, the expected result, commands and abort rules. Nothing runs them automatically, and there is no non-production environment to run them in first.

**Risk:**
- The reliability features (PDB, HPA, zone spread, zonal shift) are designed but unproven under failure.
- The plan itself predicts two weak spots: the zone spread rule (`DoNotSchedule`) can leave pods Pending after an AZ loss, and the fixed-size node group caps what the HPA can add.

**Improvement:**
- Run the plan, starting with the least disruptive experiments, and fix what it finds.
- Codify the experiments as AWS FIS templates in Terraform, with a CloudWatch alarm as the stop condition, and run them on a schedule.
- Add a production-shaped test environment so experiments don't have to start in production.
