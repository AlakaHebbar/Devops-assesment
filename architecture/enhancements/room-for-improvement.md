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
| 3 | CI | 3.1, 3.3, 3.4 | [Direct pushes to main are still allowed](#3-direct-pushes-to-main-are-still-allowed) |
| 4 | Reliability | — | [Backup and restore is a runbook, not automation](#4-backup-and-restore-is-a-runbook-not-automation) |
| 5 | Reliability | — | [Chaos testing is a plan, not automation](#5-chaos-testing-is-a-plan-not-automation) |

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

**Improvement:** a dedicated rollback workflow (`workflow_dispatch`, input: target SHA) that checks the image exists in ECR and commits that tag. It has no build, no flags to remember, and leaves an audit trail.

## 3. Direct pushes to main are still allowed

**Today:** part of this is handled in GitHub settings:
- The `protect-main` ruleset blocks deleting or force-pushing `main`.
- The `production` environment requires a reviewer's approval and accepts deployments only from `main`. Terraform `apply` cannot run without that approval.

Pushes to `main` itself are not restricted. [`update-image-tag.sh`](../../.github/scripts/update-image-tag.sh) pushes the deploy commit with `GITHUB_TOKEN`, and a "require pull request" rule would block that push, because `GITHUB_TOKEN` can't be a ruleset bypass actor.

**Risk:**
- Anyone with write access can push to `main` without a PR. An app change deploys straight to production, with no review.
- An infra change pushed this way still waits for approval, but the approver sees no PR plan.
- Admins can bypass the `production` environment's protection rules.

**Improvement:**
- Push deploy commits as a dedicated GitHub App (contents: write, minted with `actions/create-github-app-token`), and add `paths-ignore: [k8s/kustomization.yaml]` to the `push` trigger of `app-ci.yml`. App-token pushes trigger workflows, unlike `GITHUB_TOKEN`, so without it each deploy commit would build again.
- Extend `protect-main` to require a pull request and the `gitleaks` check, with the deploy App as the only bypass actor. Alternatively, CI opens an auto-merging PR for each tag bump (3.1 allows either).
- Add a CODEOWNERS file for `k8s/`, `infra/` and `.github/`, and require code-owner review once there is a second reviewer.
- Turn off admin bypass on the `production` environment.

## 4. Backup and restore is a runbook, not automation

**Today:** the service is stateless, so recovery means rebuilding from Git and the Terraform state. [backup-and-restore.md](backup-and-restore.md) lists what can be lost, how each piece is protected (state bucket versioning, `prevent_destroy`, immutable ECR tags, Secrets Manager and KMS recovery windows), and the commands to recover from nine scenarios, from a bad release to losing the cluster.

**Risk:**
- Every copy lives in the same account and region. A compromised admin or a region outage takes the state bucket with it.
- The `infra/bootstrap` state is a local file.
- The procedures haven't been drilled, so the 1-hour rebuild estimate is unproven.

**Improvement:**
- Replicate the state bucket to a separate backup account with S3 Cross-Region Replication and Object Lock.
- Move the bootstrap state into the bucket it creates.
- Run the drills listed in the runbook and record the real recovery time.
- Add Velero, or AWS Backup for a database, once anything stateful appears.

## 5. Chaos testing is a plan, not automation

**Today:** [chaos-test-plan.md](chaos-test-plan.md) defines ten experiments (pod, node and AZ loss, CPU load, a bad release, Argo CD and CoreDNS outages), each with the protection it tests, the expected result, commands and abort rules. Nothing runs them automatically, and there is no non-production environment to run them in first.

**Risk:**
- The reliability features (PDB, HPA, zone spread, zonal shift) are designed but unproven under failure.
- The plan itself predicts two weak spots: the zone spread rule (`DoNotSchedule`) can leave pods Pending after an AZ loss, and the fixed-size node group caps what the HPA can add.

**Improvement:**
- Run the plan, starting with the least disruptive experiments, and fix what it finds.
- Codify the experiments as AWS FIS templates in Terraform, with a CloudWatch alarm as the stop condition, and run them on a schedule.
- Add a production-shaped test environment so experiments don't have to start in production.
