# Phase 2 - GitOps & monitoring (IN PROGRESS: 2a partly verified, 2b not started)

## RESUME HERE

Branch: `feat/phase-2-gitops` (pushed, **no PR opened yet**). Session was stopped early; the
KodeKloud playground gets wiped, so the cluster does not survive. Next session starts from a
fresh account.

**Done and verified (2a):**
- Step 0: Phase 1 status output recorded in `docs/phases/01-infrastructure.md` section 6.
- `bootstrap.sh`: `check` (helm required; argocd/sops/age warn only), `up` (terraform + helm
  install Argo CD + root App of Apps + wait + UI/password hint), `status` (Argo summary), `down`
  (stops Argo controller first so selfHeal cannot recreate what is deleted).
- `platform/`: App of Apps (`platform/apps` Helm chart), wave 0: self-managed Argo CD,
  aws-ebs-csi-driver, gp3 default StorageClass (+ gp2 explicitly non-default).
- `./bootstrap.sh up` ran with `GITOPS_REVISION=feat/phase-2-gitops`: 4 apps Synced/Healthy in
  3m14s, terraform no-op.
- YOU RUN (a) `kubectl get applications -n argocd` and `kubectl get sc`: verified.
- YOU RUN (b) selfHeal demo: verified (see section 4 and 5).

**Not done yet:**
- (c) PVC test on gp3 (create PVC + pod, Bound + Running, delete both).
- (d) LoadBalancer test (tiny `Service type=LoadBalancer`, confirm ELB created, delete, confirm
  ELB gone).
- 2b: Wave 1 slim kube-prometheus-stack (Prometheus emptyDir, no persistence, short retention,
  must fit 3 x t3.medium), 3 alert rules, crashing-pod proof that the restarts alert fires,
  Grafana admin password generated at bootstrap into a Secret, SOPS + age scaffold + README
  section, docs/third-party.md entry for kube-prometheus-stack, README + cheatsheet updates.
- This doc: sections 2, 3, 6-10 below are placeholders until the above is done.
- Local note: `helm template` of the EBS CSI chart timed out on the dev machine (download from
  GitHub release assets). The cluster fetched it fine; not a repo problem.

**Resume commands (new session, fresh playground):**
```bash
cd ~/prod-drills-claude && git checkout feat/phase-2-gitops && git pull
aws sts get-caller-identity                      # confirm expected account/region
./bootstrap.sh check
GITOPS_REVISION=feat/phase-2-gitops ./bootstrap.sh up --env kodekloud
./bootstrap.sh status --env kodekloud
```
Then continue with (c), (d), 2b. When 2b is pushed, merge-ready state means: PR open, you merge.
If you stop again: `./bootstrap.sh down --env kodekloud` before the session ends.

---

## 1. Goal

Argo CD manages everything inside the cluster. `./bootstrap.sh up` = Terraform + Argo CD, and Argo
syncs the rest of the platform from this public Git repo (App of Apps, sync waves, selfHeal, prune).
2a covers Argo self-management plus storage (EBS CSI + gp3 default); 2b adds monitoring and the
SOPS scaffold.

## 2. Architecture

TODO (finish with 2b).

## 3. What was built

TODO (finish with 2b). So far: `bootstrap/root.yaml`, `platform/apps/` (chart: Application per
component), `platform/values/{argocd,aws-ebs-csi-driver}.yaml`, `platform/storage/storageclasses.yaml`,
bootstrap.sh changes.

## 4. Working commands

Only commands verified in this session, in run order.

```bash
GITOPS_REVISION=feat/phase-2-gitops ./bootstrap.sh up --env kodekloud
# ends with 4 apps (root, argocd, aws-ebs-csi-driver, storage) Synced Healthy; took 3m14s
```

```bash
kubectl get applications -n argocd
# NAME                 SYNC STATUS   HEALTH STATUS
# argocd               Synced        Healthy
# aws-ebs-csi-driver   Synced        Healthy
# root                 Synced        Healthy
# storage              Synced        Healthy

kubectl get sc
# gp2             kubernetes.io/aws-ebs   ...
# gp3 (default)   ebs.csi.aws.com         ... true
```

selfHeal demo (valid attempt): scale the EBS CSI controller away from what Git says (1 replica).

```bash
kubectl scale deploy ebs-csi-controller -n kube-system --replicas=3
kubectl get deploy ebs-csi-controller -n kube-system -w
# Observed generation / desired replicas: GEN 2 / 1  ->  GEN 3 / 3  ->  GEN 4 / 1; READY never > 1
```

Argo application-controller log (UTC):

```text
14:14:23Z  Synced -> OutOfSync   "Initiated automated sync"  (SelfHealAttemptsCount: 1, Resources: [Deployment ebs-csi-controller])
14:14:24Z  OutOfSync -> Synced
```

Revert took ~1 second after Argo noticed the drift. Settings in play: `selfHeal: true`,
`prune: true`, no `ignoreDifferences` on this app.

## 5. Problems hit and fixes

| Error message | Root cause | Command that failed | Command that worked | Lesson |
|---|---|---|---|---|
| No revert after a manual change; Argo log: `Skipping auto-sync: Synced`; Deployment generation only went 1 -> 2 | The `kubectl edit` changed a `replicas` line that was not `spec.replicas` (so the desired state Argo compares did not change; Argo saw no drift). Exact edited line not captured. | `kubectl edit deploy ebs-csi-controller -n kube-system` | `kubectl scale deploy ebs-csi-controller -n kube-system --replicas=3` | `kubectl edit` is error-prone for drift demos. Verify a change took effect via `metadata.generation` / `managedFields` before concluding anything about Argo. |
| `helm template` of aws-ebs-csi-driver chart: `context deadline exceeded` downloading from release-assets.githubusercontent.com | Dev machine network to GitHub release assets was slow/blocked; chart tarball is hosted there. Not a chart/repo bug. | `helm template e aws-ebs-csi-driver/aws-ebs-csi-driver --version 2.68.1 -f ...` | Skipped local render; the cluster pulled the chart successfully via Argo. | Local render is a nicety, not a gate; validate in-cluster. |

## 6. How to verify

TODO (finish with 2b). 2a so far: `kubectl get applications -n argocd` all Synced/Healthy;
`kubectl get sc` shows gp3 as the only default.

## 7. Rollback / teardown

`./bootstrap.sh down --env kodekloud` (scales the Argo controller to 0 first, then removes
LoadBalancer Services and PVCs, then terraform destroy). Finish the rest of this section with 2b.

## 8. Concepts

TODO (App of Apps vs ApplicationSet, sync waves, selfHeal, prune, why Argo renders Helm with
`helm template` so `helm list` shows nothing for Argo apps, why Argo manages itself).

## 9. Interview questions

TODO.

## 10. Break it

TODO.
