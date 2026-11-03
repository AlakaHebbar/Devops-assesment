# Backup and restore runbook

## What there is to lose

The service is stateless: no database, no volumes, no user uploads. So "backup" here means being able to **rebuild** the platform, and to keep the few things that can't be rebuilt.

| Asset | Source of truth | Protection today | Recovery |
|---|---|---|---|
| Workloads and add-ons in the cluster | Git (`k8s/`) | Git history; GitHub | Argo CD re-syncs from Git |
| Which image runs | Git (`kustomization.yaml`) | Git history | `git revert` |
| AWS infrastructure | Terraform code + state | State bucket: versioned, KMS, `prevent_destroy`; old versions kept 90 days | Restore a state version, re-apply |
| Container images | ECR | Immutable tags; last 50 tagged images kept | Rebuild from the commit, or redeploy an older tag |
| Application logs | S3 log archive | Versioned (old versions kept 30 days), KMS, lifecycle tiering | Restore an older object version |
| Argo CD deploy key | Secrets Manager | 30-day recovery window on delete | Restore the secret, or issue a new key |
| KMS keys (state, logs, EKS secrets) | KMS | 30-day deletion window | Cancel the deletion |
| Terraform state of `infra/bootstrap` | **Local file**, held by an administrator | None by design | Re-import (see scenario 7) |

**Targets:**
- **RPO (data lost):** zero for config and code, since it's all in Git. Up to the Fluent Bit buffer for logs, which is minutes.
- **RTO (time to recover):** about 1 hour to rebuild the whole platform, mostly EKS cluster creation.

All commands below assume a shell in the production account with an admin role, `STATE_BUCKET` set to the state bucket and `LOG_BUCKET` to the log bucket.

## Scheduled checks

| When | Check |
|---|---|
| Monthly | Restore drill: download an older state version (scenario 2, steps 2–3) and check it with `jq`, without pushing it. |
| Yearly, or before a big change | Full rebuild drill (scenario 6) in a throwaway account. Record how long it took. |
| On every change to `infra/bootstrap` | Copy its local state into the team's password manager or a separate secure bucket. |

## Scenarios

### 1. A bad release

Covered by the deploy flow: `git revert <bad commit>` and push. See [Rollback in ARCHITECTURE.md](../../ARCHITECTURE.md#gitops-argo-cd). No backup is involved.

### 2. Terraform state is corrupted, or a bad apply wrote it

1. Stop the pipeline from applying: leave the `production` approval pending, or disable the `infra` workflow.
2. List the versions of the state object:

   ```bash
   aws s3api list-object-versions --bucket "$STATE_BUCKET" \
     --prefix "prod/core.tfstate" \
     --query 'Versions[].{id:VersionId,at:LastModified,latest:IsLatest}' --output table
   ```

3. Download the last good version and inspect it:

   ```bash
   aws s3api get-object --bucket "$STATE_BUCKET" --key "prod/core.tfstate" \
     --version-id <good-version-id> good.tfstate
   jq '.serial, .lineage, (.resources | length)' good.tfstate
   ```

4. Push it back as the current state. `push` checks the lineage and refuses a lower serial unless forced, so read the plan carefully first:

   ```bash
   terraform -chdir=infra/environments/prod init -backend-config=backend.hcl
   terraform -chdir=infra/environments/prod state push -force ../../../good.tfstate
   ```

5. Run `terraform plan`. It should only show what really changed since that version. Fix any drift with `import` or `state rm`, never by deleting resources.
6. Delete `good.tfstate` locally, since it contains secrets.

### 3. Terraform state is deleted

The bucket is versioned, so a delete only adds a delete marker. Remove the marker to bring the object back:

```bash
aws s3api list-object-versions --bucket "$STATE_BUCKET" --prefix "prod/core.tfstate" \
  --query 'DeleteMarkers[?IsLatest].VersionId' --output text
aws s3api delete-object --bucket "$STATE_BUCKET" --key "prod/core.tfstate" --version-id <marker-id>
```

Then run `terraform plan` and expect no changes.

### 4. A resource in the cluster is deleted or changed by hand

Nothing to do: Argo CD self-heal puts it back within one sync (up to 3 minutes). To speed it up, sync the app in the Argo CD UI.

### 5. An image is missing from ECR

ECR keeps the last 50 tagged images. To roll back past that window:
1. Check out the commit.
2. Rebuild by running the `app-ci` workflow from that commit, or by reverting to it on `main`.

The rebuilt image has the same tag, but not the same digest.

### 6. The cluster is lost (or the whole platform is rebuilt)

1. **Infrastructure:** re-run the pipeline, or as an operator:

   ```bash
   terraform -chdir=infra/environments/prod apply
   ```

   With the state intact, Terraform recreates only what's missing (the cluster, node group, add-ons).
2. **Deploy key:** check that `prod/argocd/repo-deploy-key` still has a value in Secrets Manager. If it was deleted less than 30 days ago:

   ```bash
   aws secretsmanager restore-secret --secret-id "prod/argocd/repo-deploy-key"
   ```

   Otherwise create a new key pair, following step 3 of [infra/README.md](../../infra/README.md).
3. **GitOps:** re-run `infra/gitops-bootstrap` from inside the VPC. Its state may point at the old cluster, so start clean:

   ```bash
   terraform -chdir=infra/gitops-bootstrap init -backend-config=../environments/prod/backend.hcl
   terraform -chdir=infra/gitops-bootstrap state list   # then remove stale entries with `state rm`
   terraform -chdir=infra/gitops-bootstrap apply \
     -var state_bucket=$STATE_BUCKET -var gitops_repo_url=git@github.com:<owner>/<repo>.git
   ```

4. **Everything else** comes back on its own: Argo CD syncs the add-ons, the service at the image tag in Git, and external-dns points DNS at the new ALB.
5. **Verify:** all Argo CD apps are Synced and Healthy, `curl https://<domain>/api/health` returns `200`, and logs arrive in the log bucket.

### 7. The state bucket or `infra/bootstrap` state is lost

`prevent_destroy` stops Terraform from deleting the bucket, so this needs a deliberate manual delete.
- **Bucket gone:** recreate it with `infra/bootstrap`, then bring the core stack back under management with `terraform import`. That is slow, so it's the reason the bucket is protected.
- **Bootstrap's local state gone:** the bucket still exists. Re-import it into a fresh local state:

  ```bash
  terraform -chdir=infra/bootstrap init
  terraform -chdir=infra/bootstrap import aws_s3_bucket.state "$STATE_BUCKET"
  # repeat for the KMS key, alias, versioning, encryption, policy, etc., then:
  terraform -chdir=infra/bootstrap plan    # expect no changes
  ```

### 8. Log objects are deleted or overwritten

Old versions are kept for 30 days. Restore one by copying it over itself:

```bash
aws s3api copy-object --bucket "$LOG_BUCKET" --key <key> \
  --copy-source "$LOG_BUCKET/<key>?versionId=<version-id>"
```

### 9. A KMS key is scheduled for deletion

Data encrypted with it becomes unreadable once the key is deleted. Within the 30-day window:

```bash
aws kms cancel-key-deletion --key-id <key-arn>
aws kms enable-key --key-id <key-arn>
```

## Gaps and next steps

- **No copy outside the account or region.** A compromised admin, or a region outage, takes the state bucket with it. Add S3 Cross-Region Replication of the state bucket to a separate backup account, with Object Lock.
- **The bootstrap state is a local file.** Move it into the bucket it creates (see item 7 in [room-for-improvement.md](room-for-improvement.md)).
- **Velero** is not needed while nothing in the cluster holds data. Add it, with EBS snapshots, the first time a stateful workload or PersistentVolume appears.
- **A database** would bring real backups: RDS automated backups with point-in-time recovery, AWS Backup plans with cross-account copies, and restore drills of their own.
