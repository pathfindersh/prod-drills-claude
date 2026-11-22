# Phase 2 - GitOps & monitoring (Argo CD, Prometheus, Grafana)

> Status: everything below marked "verified" was run in a live KodeKloud session. Items marked
> **PENDING** were not yet confirmed when this was written (see section 6).

## 1. Goal

Argo CD manages everything inside the cluster. After this phase `./bootstrap.sh up` is
Terraform + Argo CD, and Argo syncs the rest of the platform from this public Git repo using an
App of Apps: self-managed Argo CD, the EBS CSI driver, a gp3 default StorageClass and
metrics-server (wave 0), then a slim Prometheus/Grafana/Alertmanager stack with three alert rules
(wave 1). It also closes Phase 1's open checks (PVCs and LoadBalancers really work) and scaffolds
SOPS + age for future persistent secrets.

## 2. Architecture

```
 git (public, GitHub)                      EKS cluster demo-eks (3 x t3.medium)
┌─────────────────────────┐   HTTPS poll  ┌──────────────────────────────────────────────────────┐
│ bootstrap/root.yaml     │◄──────────────│ ns argocd:  Argo CD (helm-installed once by          │
│ platform/apps  (chart)  │               │             bootstrap.sh, then manages itself)       │
│ platform/values/*.yaml  │               │   root (App of Apps) ──renders platform/apps──┐      │
│ platform/storage/*.yaml │               │                                               ▼      │
└─────────────────────────┘               │  wave 0: argocd | aws-ebs-csi-driver | metrics-server│
        ▲                                 │          | storage (gp3 default, gp2 non-default)    │
        │ git push = deploy               │  wave 1: kube-prometheus-stack (ns monitoring)       │
 you ───┘                                 │          Prometheus(emptyDir) Grafana Alertmanager   │
 bootstrap.sh up ─ terraform ─► EKS       │          + 3 rules  + Secret grafana-admin (random)  │
              └ helm install argo-cd ───► │                                                      │
              └ kubectl apply root.yaml ► │  PVC ─► EBS CSI ─► EBS gp3   Service LB ─► classic ELB│
                                          └──────────────────────────────────────────────────────┘
```

## 3. What was built

| File / resource | Purpose |
|---|---|
| `bootstrap.sh` | `check` (+helm required; argocd/sops/age warn-only), `up` (+Argo install, root app, wait, UI hints, Grafana secret), `status` (+Argo summary), `down` (+stops Argo controller first so selfHeal can't recreate deleted LBs/PVCs) |
| `bootstrap/root.yaml` | App of Apps root; `GITOPS_REVISION` rewrites its branch for pre-merge testing |
| `platform/apps/` | Helm chart emitting one Application per component; versions pinned in `values.yaml` |
| `platform/values/argocd.yaml` | Slim Argo values, shared by the bootstrap install and the self-managing app |
| `platform/values/aws-ebs-csi-driver.yaml` | EBS CSI (1 controller, node-role credentials via IMDS) |
| `platform/values/metrics-server.yaml` | `kubectl top` + Phase 3 HPA |
| `platform/storage/storageclasses.yaml` | gp3 default; gp2 explicitly non-default (`Prune=false`) |
| `platform/values/kube-prometheus-stack.yaml` | Slim monitoring, emptyDir Prometheus, 6h retention, 3 alert rules |
| `monitoring/grafana-admin` Secret | Random Grafana admin password, created by `bootstrap.sh`, never in Git |
| `.sops.yaml`, `secrets/`, README section | SOPS + age scaffold (placeholder recipient, no secrets) |
| `docs/third-party.md` | Every upstream chart/version with reason |

## 4. Working commands

Only commands verified this phase, in run order. Account IDs, timings and hashes are from the
sessions where they ran.

```bash
GITOPS_REVISION=feat/phase-2-gitops ./bootstrap.sh up --env kodekloud
# terraform no-op, helm install argo-cd, root applied, 4 apps Synced+Healthy (3m14s in the first session)
# prints the Argo UI port-forward and a generated admin password (once; never copy it anywhere)

kubectl get applications -n argocd
# argocd / aws-ebs-csi-driver / root / storage   all   Synced   Healthy
kubectl get sc
# gp2  kubernetes.io/aws-ebs ...      gp3 (default)  ebs.csi.aws.com ... true
```

selfHeal demo (scale away from what Git says, Argo puts it back):

```bash
kubectl get deploy ebs-csi-controller -n kube-system -w &
kubectl scale deploy ebs-csi-controller -n kube-system --replicas=3
# observed generation/desired: 2/1 -> 3/3 -> 4/1, READY never > 1
# Argo log: 14:14:23Z Synced->OutOfSync "Initiated automated sync" (SelfHealAttemptsCount 1,
#           Deployment ebs-csi-controller); 14:14:24Z OutOfSync->Synced   (~1 s to revert)
```

PVC test on gp3, with the AWS-side check:

```bash
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: pvc-test, namespace: default }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: pvc-test, namespace: default }
spec:
  containers:
    - name: c
      image: public.ecr.aws/docker/library/busybox:1.36
      command: ["sh", "-c", "echo hello > /data/f && cat /data/f && sleep 3600"]
      volumeMounts: [{ name: d, mountPath: /data }]
  volumes: [{ name: d, persistentVolumeClaim: { claimName: pvc-test } }]
YAML
kubectl wait --for=condition=Ready pod/pvc-test --timeout=180s   # pod/pvc-test condition met
kubectl get pvc,pod pvc-test       # Bound, gp3, 1Gi, RWO ; pod 1/1 Running
kubectl logs pvc-test              # hello
VOL=$(kubectl get pv -o jsonpath='{.items[0].spec.csi.volumeHandle}'); echo "$VOL"
aws ec2 describe-volumes --volume-ids "$VOL" --query 'Volumes[0].[VolumeId,VolumeType,Size,State]' --output text
# vol-...  gp3  1  in-use
kubectl delete pod/pvc-test pvc/pvc-test
kubectl get pv                     # PV shows Released for a moment, then disappears
sleep 30
aws ec2 describe-volumes --volume-ids "$VOL" --query 'Volumes[0].State' --output text 2>&1
# InvalidVolume.NotFound  (volume deleted in AWS)
```

LoadBalancer test:

```bash
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Service
metadata: { name: lb-test, namespace: default }
spec:
  type: LoadBalancer
  selector: { app: does-not-exist }
  ports: [{ port: 80, targetPort: 80 }]
YAML
for i in $(seq 1 30); do H=$(kubectl get svc lb-test -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'); [ -n "$H" ] && break; sleep 10; done; echo "ELB: $H"
# ELB: a<hash>-<digits>.us-east-1.elb.amazonaws.com   (~14 s)
aws elb describe-load-balancers --query "LoadBalancerDescriptions[?DNSName=='$H'].[LoadBalancerName,Scheme,VPCId]" --output text
# <name>  internet-facing  vpc-...
kubectl delete svc lb-test
sleep 45
aws elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text   # (empty)
```

Grafana admin Secret (only needed on a cluster brought up before `bootstrap.sh` learned to do it;
a fresh `up` does this itself):

```bash
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
GP=$(openssl rand -hex 16)
kubectl -n monitoring create secret generic grafana-admin --from-literal=admin-user=admin --from-literal=admin-password="$GP"
echo "password (shown once): $GP"; unset GP
```

Monitoring sync, capacity and the restart-alert proof:

```bash
kubectl get applications -n argocd
# argocd, aws-ebs-csi-driver, kube-prometheus-stack, metrics-server, root, storage  all Synced Healthy
kubectl get pods -n monitoring     # alertmanager 2/2, grafana 3/3, kube-state-metrics, operator, 3x node-exporter, prometheus 2/2
kubectl top nodes                  # works (metrics-server); node memory 27-58%
kubectl describe nodes | grep -A8 "Allocated resources"
# requests: cpu 19-26%, memory 17-26% of allocatable on every node

kubectl run crash-test --image=public.ecr.aws/docker/library/busybox:1.36 --restart=Always -- sh -c 'echo boom; exit 1'
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 &
curl -s localhost:9090/api/v1/alerts | jq '.data.alerts[] | {alertname: .labels.alertname, pod: .labels.pod, state}'
# observed: restarts=1..3 alert=none -> restarts=4 alert=pending (17:52:09) -> alert=firing (17:53:11)
# {"alertname":"PodRestartingFrequently","pod":"crash-test","state":"firing"}
kubectl delete pod crash-test
```

## 5. Problems hit and fixes

| Error message | Root cause | Command that failed | Command that worked | Lesson |
|---|---|---|---|---|
| No revert after a manual change; Argo log `Skipping auto-sync: Synced`; Deployment generation only 1 -> 2 | The `kubectl edit` changed a `replicas` line that was not `spec.replicas`, so the desired state Argo compares never changed (exact edited line not captured) | `kubectl edit deploy ebs-csi-controller -n kube-system` | `kubectl scale deploy ebs-csi-controller -n kube-system --replicas=3` | `kubectl edit` is error-prone for drift demos. Verify with `metadata.generation` / `managedFields` before drawing conclusions about Argo |
| `helm template` of the EBS CSI chart: `context deadline exceeded` fetching from release-assets.githubusercontent.com | Dev-machine network to GitHub release assets was slow; the chart tarball is hosted there. Not a chart bug | `helm template e aws-ebs-csi-driver/aws-ebs-csi-driver --version 2.68.1 -f ...` | skipped local render; the cluster pulled it fine  via Argo | Local render is a nicety, not a gate; validate in-cluster |
| Grafana pod `3/3 Running` but `RESTARTS 2`; `lastState.terminated.reason: OOMKilled`, `exitCode: 137`, ran 5 s (11:53:45Z -> 11:53:50Z). `kubectl logs --previous` ended abruptly mid plugin install, no error | Grafana's startup plugin pre-install pushed memory past the 256Mi limit; the kernel OOM killer sent SIGKILL | (deployed as-is with `limits.memory: 256Mi`) | `grafana.env.GF_PLUGINS_PREINSTALL_DISABLED: "true"` and `limits.memory: 384Mi` in `platform/values/kube-prometheus-stack.yaml` (commit ba8d2c8). **PENDING:** result of the fix | A log that stops mid-line with no error means the process was killed from outside: check `lastState` (reason, exit code), not just logs. Size limits for startup peaks, not steady state |
| `kubectl get pv` right after deleting the PVC showed the PV `Released`, not gone | The CSI driver deletes the EBS volume asynchronously after the claim is removed (`reclaimPolicy: Delete`) | `kubectl get pv` (immediately) | `sleep 30` then `aws ec2 describe-volumes --volume-ids "$VOL"` -> `InvalidVolume.NotFound` | Trust the AWS-side check, not the instant kubectl view |

## 6. How to verify

```bash
./bootstrap.sh status --env kodekloud    # nodes Ready + "Argo: all apps Synced+Healthy"
kubectl get applications -n argocd        # 6 apps Synced Healthy
kubectl get sc                            # gp3 is the only (default)
kubectl top nodes                         # metrics-server works
kubectl get pods -n monitoring            # all Running; Grafana restarts stay put
```

- PVC test (section 4) shows Bound/Running and the EBS volume deleted afterwards.
- LoadBalancer test (section 4) shows the ELB created, then gone.
- selfHeal: scale a managed Deployment; it reverts within seconds.
- Restart alert: crash-test pod makes `PodRestartingFrequently` go pending then firing.
- **PENDING:** Grafana (port-forward `svc/kube-prometheus-stack-grafana` 3000:80, user `admin`, password
  from `kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d`)
  lists the 3 rules under Alerting -> Alert rules; and Grafana pod restart count stays 0 after the OOM fix.
- Note: `High5xxRate` and `HighP95Latency` have no data until Phase 3 exposes
  `http_requests_total` / `http_request_duration_seconds`; they are loaded but cannot fire yet.

## 7. Rollback / teardown

- Whole lab: `./bootstrap.sh down --env kodekloud`. It scales the Argo application-controller to 0
  first (otherwise selfHeal recreates what it deletes), removes LoadBalancer Services and PVCs, waits
  for ELBs to vanish, then `terraform destroy` and the leftover check.
- One component: delete its file under `platform/apps/templates/` and push; `prune: true` removes it.
  (Argo-managed resources reappear if you `kubectl delete` them: that is selfHeal.)
- Production difference: Prometheus here uses emptyDir, so a pod reschedule loses all history. In
  production give it a PVC (or remote-write) and size retention for it.

## 8. Concepts

- **GitOps**: Git is the source of truth; a controller makes the cluster match it. *Analogy: a thermostat
  with a target in a file, not a person turning the dial.* Matters because changes are reviewed,
  auditable and reversible with `git revert`.
- **App of Apps vs ApplicationSet**: the root Application points at a chart that emits child
  Applications (explicit, hand-written, easy to order with waves). An ApplicationSet generates
  Applications from a template plus a generator (list of clusters, directories, PRs): better for many
  similar apps/clusters. We have ~6 distinct components, so App of Apps; ApplicationSet adds
  indirection for no gain here.
- **Sync waves**: annotation `argocd.argoproj.io/sync-wave` orders resources/Applications; Argo waits
  for a wave to be Healthy before the next. *Analogy: foundations before walls.* Storage and Argo
  first, monitoring second.
- **selfHeal**: Argo reverts manual drift (we saw a scale revert in ~1 s). Without it, `kubectl`
  hotfixes silently diverge from Git.
- **prune**: Argo deletes live resources removed from Git. Without it, deleted manifests linger forever.
  `Prune=false` on gp2 protects something we don't own.
- **Why `helm list` shows nothing for Argo apps**: Argo runs `helm template` and applies the plain
  manifests itself; no Helm release object is created. Argo, not Helm, owns lifecycle and drift
  detection. (Only the bootstrap install of Argo itself is a real Helm release, which Argo then adopts.)
- **Why Argo manages itself**: its own config and upgrades go through Git/PR like everything else.
  Risk: a bad Argo change can break the thing that would fix it, so the bootstrap install and the
  Git values must stay identical (one shared values file).
- **Exit code 137**: 128 + 9 (SIGKILL). In Kubernetes, with `reason: OOMKilled`, the kernel OOM killer
  killed the container for exceeding its memory limit. *Analogy: a bouncer removing someone who
  exceeded the room's capacity, with no warning.* Logs just stop; `lastState` tells you why.
- **Requests vs limits**: the scheduler uses requests to place pods; limits are enforced at runtime
  (memory over limit = OOMKill). `kubectl describe nodes` shows what the scheduler sees.
- **SOPS + age**: encrypt only secret values in Git files with a public key; decrypt with a private
  key supplied via `SOPS_AGE_KEY`. Keeps secrets reviewable and out of plaintext history.

## 9. Interview questions

1. **App of Apps vs ApplicationSet?** App of Apps: a parent Application whose source contains child
   Applications; explicit and orderable. ApplicationSet generates many Applications from generators
   (clusters, dirs, PRs); better at scale or for per-cluster fan-out.
2. **What do selfHeal and prune do, and what can go wrong?** selfHeal reverts live drift to Git; prune
   deletes resources removed from Git. Risks: emergency manual fixes are reverted, and pruning can
   delete things you don't own, so protect them (`Prune=false`).
3. **Why does `helm list` show nothing for Argo-managed charts?** Argo renders with `helm template` and
   applies manifests directly; there is no Helm release.
4. **A pod restarts with exit code 137 and logs that stop abruptly. Diagnosis?** SIGKILL, most likely
   OOMKilled: confirm with `kubectl get pod -o jsonpath` on `lastState.terminated.reason`, then fix the
   memory limit or the startup spike.
5. **Why order platform components with sync waves?** Dependencies: storage driver and CRDs must be
   healthy before workloads that need them; Argo waits for each wave to be Healthy.

## 10. Break it

1. **Argo/Git drift fight**: change the Argo values in Git but not the bootstrap-time install (or edit
   a managed resource by hand). Watch OutOfSync/selfHeal loops and a broken self-managed Argo.
2. **Memory starvation**: lower Grafana (or Prometheus) memory limits, or add pods until node
   requests exceed allocatable. Observe OOMKilled (137) and `Pending` pods with `Insufficient memory`.
3. **Teardown leak**: delete the Argo controller state or skip the `down` ordering with a live
   `Service type=LoadBalancer`/PVC: ELB or EBS volume survives `terraform destroy` and blocks VPC
   cleanup/costs money (`leftover_check` catches it).
