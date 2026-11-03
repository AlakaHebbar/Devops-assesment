# Deployment strategy: rolling update

**Choice:** a Kubernetes rolling update that never drops below the desired number of ready pods. It's configured in [`deployment.yaml`](../k8s/deployment.yaml):

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 25%        # with 3 replicas: 1 extra pod at a time
    maxUnavailable: 0    # never fewer ready pods than desired
```

## Why rolling update

| Need | How a rolling update meets it |
|---|---|
| **Zero downtime** | `maxUnavailable: 0`: an old pod is removed only after a new one passes its readiness probe. |
| **Low cost** | It needs one extra pod during a rollout. Blue-green needs a full second copy of the service for the whole switch. |
| **Simple** | It's built into Kubernetes, and Argo CD already shows its progress. No extra controller or CRDs to run, upgrade and secure. |
| **Fits the app** | The service is stateless, with no database and no schema migrations. Old and new versions can serve side by side for the minute a rollout takes. |
| **Fits the rollback model** | A rollback is a `git revert`, which is just another rolling update to the previous image. |

## How a rollout runs

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

## Alternatives considered

| Strategy | Why not now |
|---|---|
| **Recreate** | Stops every old pod before starting new ones, so every release is an outage. |
| **Blue-green** | Instant switch and instant switch-back, but it doubles capacity during each release. Switching ALB traffic needs Argo Rollouts or a second Service and Ingress. A bad release still hits 100% of users at once, just with a faster way back. |
| **Canary** | The best protection, since only a slice of traffic sees the new version first. But it needs Argo Rollouts, ALB weighted target groups, and metrics to judge the canary (5xx rate and latency). There are no ALB 5xx or latency alarms yet. A canary without analysis is just a slower rolling update. |

## When to move to canary

Move to a canary once the service has real traffic and ALB metrics. The upgrade path is short:
1. Install Argo Rollouts with an ApplicationSet in `k8s/platform/`.
2. Replace the Deployment with a `Rollout`: `canary` with `trafficRouting.alb`, steps of 10% → 50% → 100%, with pauses.
3. Add an `AnalysisTemplate` that queries CloudWatch for ALB 5xx and p95 latency. A failed analysis aborts and shifts traffic back automatically.

This also closes items 3 and 4 in [room-for-improvement.md](room-for-improvement.md).

## Known gap: ALB pod readiness gate

The namespace doesn't have the label `elbv2.k8s.aws/pod-readiness-gate-inject: enabled`. Without it, Kubernetes counts a new pod as ready once its own probe passes, which can be a few seconds before the ALB marks the target healthy. With `maxUnavailable: 0` and three replicas, the service still has healthy targets throughout, but adding the label makes each step wait for the ALB as well. It's a one-line change to [`namespace.yaml`](../k8s/namespace.yaml).
