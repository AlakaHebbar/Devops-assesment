# Chaos test plan

**Goal:** prove that the reliability features in the design work under failure, rather than assuming they do. Each experiment names the protection it tests, what we expect, and what counts as failure.

## Rules of engagement

- **Where:** uat first, which has prod's shape (3 AZs, 3 nodes). Run in prod only once an experiment has passed in uat, inside an announced window, with someone watching.
- **One experiment at a time.** Note the start and end times so the alarms and logs can be matched afterwards.
- **Steady state, measured the whole time.** In a second terminal, send traffic and count failures:

  ```bash
  URL=https://app.uat.example.com/api/health
  while true; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$URL")
    echo "$(date +%T) $code"
    sleep 0.2
  done | tee chaos-$(date +%s).log
  ```

  **Pass:** no non-`200` lines, apart from the exceptions an experiment allows. **Also watch:** `kubectl -n next-bff get pods -o wide -w` and the Argo CD UI.
- **Abort:** stop and roll back as soon as the error rate passes 1% for more than 30 s, or a pod stays Pending for more than 5 minutes when it shouldn't.
- **Access:** experiments use `kubectl` through an `eks_admin_role_arns` role (VPN or SSM), or AWS Fault Injection Service (FIS). CI never runs them, since it has no cluster access by design.

## Experiments

| # | Fault | Protections tested | Expected result |
|---|---|---|---|
| 1 | Kill one app pod | Replicas ≥ 3, readiness probe, ALB health check | No failed requests. The ReplicaSet replaces the pod within about 30 s. |
| 2 | Kill all app pods at once | Recovery time | Errors until the first new pod is ready. **Measure** the time to first `200`; target under 60 s. This shows why the PDB matters. |
| 3 | Drain one node | PDB `minAvailable: 2`, spread across hosts | The drain evicts one pod at a time and waits for replacements. No failed requests. |
| 4 | Terminate one node (EC2) | Managed node group, zone spread | The node group launches a replacement. Pods on the lost node fail over, with at most a short spike. |
| 5 | Lose an AZ (EKS zonal shift) | 3 AZs, NAT per AZ, zone spread, zonal shift | Traffic stops going to pods in that AZ. The other two AZs keep serving. |
| 6 | CPU stress on the app | HPA (70% CPU, 3–12 replicas), metrics-server | The HPA adds replicas within a few minutes. Latency rises, but no requests fail. |
| 7 | Bad release (an image that never becomes ready) | `maxUnavailable: 0`, readiness probe, smoke test | The rollout stalls, old pods keep serving, Argo CD shows Degraded. Recover with `git revert`. |
| 8 | Delete a resource by hand | Argo CD self-heal | Argo CD recreates it within one sync (up to 3 minutes). |
| 9 | Stop Argo CD | GitOps is not in the request path | The app keeps serving. Deploys pause until Argo CD is back, then catch up. |
| 10 | Kill CoreDNS pods | CoreDNS replicas, add-on management | Short DNS errors inside the cluster at most. External traffic is unaffected, since the ALB routes to pod IPs. |

### How to run each

1. **Kill one pod:**

   ```bash
   kubectl -n next-bff delete pod \
     "$(kubectl -n next-bff get pod -l app=next-bff-service -o name | shuf -n1 | cut -d/ -f2)"
   ```

2. **Kill all pods:** `kubectl -n next-bff delete pod -l app=next-bff-service --wait=false`
3. **Drain a node:** pick a node running app pods, then
   `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`. Afterwards: `kubectl uncordon <node>`.
4. **Terminate a node:** run the FIS action `aws:eks:terminate-nodegroup-instances` with `instanceTerminationPercentage = 34`, or terminate one instance in the EC2 console.
5. **Lose an AZ:** zonal shift is enabled on the cluster ([`modules/eks`](../infra/modules/eks/main.tf)). Shifting away from an AZ removes that zone's pods from the Service endpoints, so the Load Balancer Controller deregisters them from the ALB:

   ```bash
   aws arc-zonal-shift start-zonal-shift \
     --resource-identifier <eks-cluster-arn> --away-from use1-az1 \
     --expires-in 30m --comment "chaos test"
   ```

   For a harsher test, also cordon and drain every node in that AZ.
6. **CPU stress:** load the site with `hey -z 5m -c 100 https://app.uat.example.com/`, or run the FIS action `aws:eks:pod-cpu-stress`. Watch `kubectl -n next-bff get hpa -w`.
7. **Bad release:** in uat, commit an image tag that doesn't exist in ECR. The pod hits `ImagePullBackOff`. Revert the commit afterwards.
8. **Delete by hand:** `kubectl -n next-bff delete service next-bff-service`, then watch Argo CD recreate it.
9. **Stop Argo CD:** `kubectl -n argocd scale deploy --all --replicas=0`, then `kubectl -n argocd scale statefulset --all --replicas=0`. Restore by re-syncing the `argo-cd` app, or by scaling back up.
10. **Kill CoreDNS:** `kubectl -n kube-system delete pod -l k8s-app=kube-dns`

## Risks to check during the tests

- **Zone spread vs. AZ loss (experiment 5).** The zone spread rule uses `whenUnsatisfiable: DoNotSchedule`. If an AZ's nodes are lost (not just shifted away from), replacement pods may stay Pending, because placing them in the other two zones would break `maxSkew: 1`. If that happens, change the zone rule to `ScheduleAnyway`, or rely on node autoscaling. This is the most likely finding of the plan.
- **Fixed node count (experiment 6).** The HPA can go up to 12 replicas, but the node group has a fixed size. If pods go Pending, that confirms the "add Karpenter or Cluster Autoscaler" follow-up in [ARCHITECTURE.md](../ARCHITECTURE.md#production-assumptions-and-follow-ups).
- **No alert for a stalled rollout (experiment 7).** Nothing pages anyone yet. The "fewer than 2 running pods" alarm doesn't fire, because the old pods keep running.

## Automating it later

- **AWS FIS experiment templates** in Terraform (a `chaos` module), with a CloudWatch alarm as the stop condition, run against uat on a schedule.
- **In-cluster tools:** Chaos Mesh or LitmusChaos, installed by an ApplicationSet. These are more work to run safely, so they're worth it only once the manual plan passes.
- **Record results** in a table per run: date, environment, experiment, pass or fail, time to recover, follow-ups.
