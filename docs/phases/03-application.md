# Phase 3a - Application deployment (dev)

> Status: 3a done and verified (dev). 3b (test + prod, LoadBalancer, ownership check) pending. See **RESUME HERE**.

## RESUME HERE (for 3b, continued)

State at end of session 2 (branch `feat/phase-3-application`, PR #8 still DRAFT, not merged):
- DONE and verified: prefix delegation (maxPods 110 on all 3 nodes, CNI patched before nodes), node rollout, shop-dev healthy with the same redis PVC.
- DONE and verified: `./bootstrap.sh down` with the PVC fix (5m04s, clean leftover check). Lab is torn down; the next session starts from zero (`up`).
- NOT done: test + prod, gateways, proofs, ownership check, NetworkPolicy enforcement.
- Dev will not exist in a new lab unless Argo tracks this branch: `GITOPS_REVISION=feat/phase-3-application ./bootstrap.sh up --env kodekloud` (or merge PR #8 first).

Next session, in order:
1. **Fresh-up verification of prefix delegation.** On a brand-new cluster (`up` from zero) check `kubectl get nodes -o custom-columns=NAME:.metadata.name,PODS:.status.allocatable.pods` shows 110 straight away, and that the CNI env was set before the nodes joined (`terraform_data.cni_prefix` precedes the ASG). Only the in-place path (existing cluster) is verified so far.
2. **Capacity math before enabling environments.** One full environment requests 1.57 CPU / 1.37 GiB; platform ~1.36 CPU. Dev + test + prod at defaults = ~6.07 CPU > 5.79 allocatable. Plan: loadgenerator off in test/prod, trimmed requests in test, prod 2 replicas only for frontend. Recompute from live `kubectl describe nodes` before syncing. Pod slots are no longer the limit.
3. **Test + prod.** Fill `values-test.yaml` / `values-prod.yaml` (stubs now), add `test`, `prod` to `onlineBoutique.environments` in `platform/apps/values.yaml`. The frontend supports `BASE_URL` natively (`src/frontend/main.go`), so set `BASE_URL=/dev`, `/test` per env and none for prod; no URL rewriting.
4. **Gateways (Envoy Gateway, Gateway API; not ingress-nginx).** Two Gateways = two LoadBalancers. PUBLIC: `/` -> shop-prod, `/dev`, `/test`. ADMIN: `/argocd`, `/grafana`, locked with `loadBalancerSourceRanges` (EnvoyProxy `envoyService`). Hostnames, paths and CIDRs are VALUES in `platform/apps/values.yaml`. `bootstrap.sh up` detects the current public IP (HTTPS lookup, env override) and passes it as a Helm parameter; never committed. Argo CD: `server.rootpath` + `basehref` = `/argocd`; Grafana: `root_url` + `serve_from_sub_path`. Watch for the Phase 2 chart-download timeout (Envoy Gateway chart is OCI).
5. **Proofs.** Shop via public LB on all 3 paths; admin URLs work from the owner's IP and are unreachable from another source (e.g. a short-lived pod/other host curling the ELB DNS, plus the ELB security group rules).
6. **Ownership check:** every container image in `shop-*` is `ghcr.io/pathfindersh/...@sha256:...`.
7. **NetworkPolicy enforcement** (`aws-eks-nodeagent` is already present, mode `standard`; likely only the node-agent enable flag) plus a proof that a policy blocks traffic.
8. **End of session:** `down` with the PVC fix is VERIFIED (see section 4); just run it again. Then mark PR ready; owner merges; re-point Argo to main.
9. Known loose ends: `busybox` mirrored but unused; `shoppingassistantservice` address is dead; plain HTTP on both entrances until TLS (Phase 3.5).

## 1. Goal
Run the Online Boutique shop from our own repo and our own registry: source copied once into `src/`, every image mirrored byte-for-byte into `ghcr.io/pathfindersh` by a GitHub Actions workflow, one reusable Helm chart (`charts/microservice`) that every service uses, and Argo CD deploying it per environment through a service x environment ApplicationSet. 3a delivers the `dev` environment.

## 2. Architecture
```
GitHub Actions (mirror-images, GITHUB_TOKEN) --copy, same digest--> ghcr.io/pathfindersh/<svc>@sha256:...
                                                                       ^ pulled anonymously (public)
git repo (branch feat/phase-3-application)                             |
  charts/microservice  apps/online-boutique/<svc>/values*.yaml         |
  platform/apps -> root app -> ApplicationSet online-boutique          |
                          |  (matrix: 12 services x [dev])             |
                          v   multi-source: chart + $values            |
   Argo CD runs `helm template` --> 12 Applications <svc>-dev --------+
                          v
  namespace shop-dev
   frontend --> productcatalog, currency, cart, recommendation, shipping, checkout, ad
   checkout --> payment, email, cart, currency, shipping, productcatalog
   cart --> redis-cart-0 (StatefulSet + PVC data-redis-cart-0, gp3 1Gi)
   loadgenerator --> frontend
```

## 3. What was built
| file/resource | purpose |
|---|---|
| `src/<service>/`, `src/protos`, `src/LICENSE`, `src/UPSTREAM.md` | One-time copy of 11 services (Apache-2.0), upstream commit `c7cb6d5` recorded |
| `.github/workflows/mirror-images.yml` | `workflow_dispatch`; skopeo copies all platforms, checks source digest == destination digest, writes digest table to run summary |
| `charts/microservice/` | Shared chart: Deployment or StatefulSet, Service, ConfigMap, SA, NetworkPolicy, optional HPA/PDB, `values.schema.json`, README |
| `apps/online-boutique/<svc>/values.yaml` | Per-service config + image digest (shared by all envs) |
| `apps/online-boutique/<svc>/values-{dev,test,prod}.yaml` | Env overrides; dev live, test/prod stubs |
| `platform/apps/templates/online-boutique.yaml` + `onlineBoutique` in `platform/apps/values.yaml` | ApplicationSet (service x environment), dev only |
| `scripts/validate-charts.sh` | helm lint + helm template + kubeconform for every service/env |
| `ghcr.io/pathfindersh/<name>` (13 packages, public) | Our images; outlive the playground |

## 4. Working commands
Verified in the 3a session (owner ran items 2-5; item 1 and 6 verified by Claude).
```bash
# 1. Validate charts (kubeconform must be installed; Claude used a binary from github.com/yannh/kubeconform releases)
KUBECONFORM=$(which kubeconform) scripts/validate-charts.sh dev
#   -> one line per service: "Summary: N resources found ... Valid: N, Invalid: 0, Errors: 0"

# 2. Mirror images (needs PR #7 on main)
gh workflow run mirror-images.yml --ref main
gh run watch $(gh run list --workflow mirror-images.yml -L1 --json databaseId -q '.[0].databaseId')
#   -> run succeeded (4m18s, run 45426379819), digest table in the run summary

# 3. Verify a mirrored digest equals upstream (anonymous, no login)
skopeo inspect --raw docker://ghcr.io/pathfindersh/frontend:v0.10.7 | sha256sum
skopeo inspect --raw docker://us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/frontend:v0.10.7 | sha256sum
#   -> identical hashes (frontend: e1cbd4561d3c9d27...)

# 4. Re-point Argo to the branch and deploy dev (~2 min)
GITOPS_REVISION=feat/phase-3-application ./bootstrap.sh up --env kodekloud
#   -> 18 apps Synced/Healthy (12 *-dev + 6 platform)
kubectl get applications -n argocd
kubectl get pods,pvc -n shop-dev
#   -> 12 pods Running 1/1, 0 restarts; redis-cart-0; PVC data-redis-cart-0 Bound 1Gi gp3

# 5. Use the shop
kubectl -n shop-dev port-forward svc/frontend 8080:80     # browse http://localhost:8080, place an order
#   -> "Your order is complete!" with a tracking number
```
Not yet run in this session: `helm template` with `values-dev` read by the owner as a standalone step (covered by item 1).


### Prefix delegation + node rollout (session 2, all run by the owner, output confirmed)
```bash
cd infra/terraform
terraform plan  -var-file=envs/kodekloud.tfvars -var region=us-east-1 -out=p3b.tfplan   # 1 to add, 2 to change, 0 to destroy
terraform apply p3b.tfplan                      # CNI rolled out BEFORE the ASG update; Apply complete! 1 added, 2 changed
kubectl -n kube-system get ds aws-node -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ENABLE_PREFIX_DELEGATION")].value}{"\n"}'   # true

# per node (repeat x3, one at a time):
kubectl cordon <node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=180s
aws ec2 terminate-instances --region us-east-1 --instance-ids <instance-id> --query 'TerminatingInstances[0].CurrentState.Name'   # shutting-down
kubectl get nodes -w                            # replacement node appears Ready in ~2-3 min
kubectl get nodes -o custom-columns=NAME:.metadata.name,PODS:.status.allocatable.pods   # 17 -> 110

kubectl get pods,pvc -n shop-dev                # 12/12 Running, 0 restarts; data-redis-cart-0 Bound (same PV as before)
```
Result: allocatable pods 17 -> 110 on all 3 nodes; same redis PV reattached after its node was replaced.
Not yet verified: the fresh-`up` path (see RESUME HERE item 1).


### Teardown with a PVC in use (session 2, run by the owner, output confirmed)
```bash
./bootstrap.sh down --env kodekloud
#  ==> stop Argo CD controller           (3s)
#  ==> delete LoadBalancer Services      (2s)
#  ==> scale workloads in PVC namespaces to 0 (release volumes)   (37s)
#  ==> delete PVCs: persistentvolumeclaim "data-redis-cart-0" deleted from shop-dev namespace   (4s)
#  ==> terraform destroy: "Destroy complete! Resources: 23 destroyed."   (includes terraform_data.cni_prefix)
#  ==> leftover check clean (no cluster, instances, unattached volumes, load balancers)
#  ==> down complete in 5m4s
```
No timeout on the PVC and no manual scale needed: the earlier `pvc-protection` failure is fixed.

## 5. Problems hit and fixes
| error message | root cause | command that failed | command that worked | lesson |
|---|---|---|---|---|
| `timed out waiting for the condition on persistentvolumeclaims/data-redis-cart-0` during `./bootstrap.sh down` | `redis-cart-0` still mounted the PVC; the `kubernetes.io/pvc-protection` finalizer blocks deletion while a pod uses it | `kubectl delete pvc --all -A --wait=true` | `kubectl -n shop-dev scale statefulset,deployment --all --replicas=0`, then re-run `./bootstrap.sh down`. `down` now does the scale-down itself (Argo is stopped first so selfHeal cannot undo it) | Stateful workloads must be stopped before their volumes can be deleted; teardown order matters |
| `Cannot evict pod ... would violate the pod's disruption budget` (coredns) while draining node 2 | coredns PodDisruptionBudget: only 1 of 2 replicas may be down | `kubectl drain <node> ...` (first attempt) | same command, retried/left running; it succeeded once the first coredns pod was Ready on another node. No `--disable-eviction`. | The PDB is doing its job; wait for it, do not force |
| (no error) `kubeconform` hung, no output | schema download from GitHub stalled | `helm template ... \| kubeconform -strict -` | `kubeconform -cache <dir>` with `timeout`+retry (built into `scripts/validate-charts.sh`) | CI tools that fetch schemas need a cache and a timeout |
| `workflow_dispatch` unavailable on branch | GitHub only dispatches workflows present on the default branch | (anticipated, not run) `gh workflow run --ref <branch>` | workflow shipped in tiny PR #7 to main first | Workflows live on main even if everything else is on a feature branch |
| image `manifest unknown` / 403 for guessed path | upstream v0.10.7 images are published under `online-boutique-ci`, not `google-samples` | `skopeo inspect docker://us-central1-docker.pkg.dev/google-samples/microservices-demo/frontend:v0.10.7` | same with `.../online-boutique-ci/microservices-demo/...` | Verify the registry path anonymously before building automation on it |
| `redis:alpine` is a moving tag | upstream manifest uses it | n/a | mirror `redis:7.4.9-alpine`, deploy by digest | Pin versions at mirror time, digest at deploy time |

## 6. How to verify
- `scripts/validate-charts.sh dev` -> every line `Invalid: 0, Errors: 0`.
- `kubectl get applications -n argocd` -> 12 `*-dev` plus platform apps, all Synced/Healthy.
- `kubectl get pods -n shop-dev` -> all Ready; `kubectl get pvc -n shop-dev` -> Bound.
- Digest pinning: `kubectl get pods -n shop-dev -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' | grep -vc '@sha256:'` -> `0`.
- Ownership (3b, all envs): same command, plus `... | grep -v '^ghcr.io/pathfindersh/'` -> empty.
- Argo runs `helm template`: `helm list -A` shows no `*-dev` releases.
- Browser: place an order.

## 7. Rollback / teardown
- Remove dev: set `onlineBoutique.environments: []` in `platform/apps/values.yaml` and push (Argo prunes), or `kubectl delete applicationset online-boutique -n argocd` (cascades to Applications and their resources). The redis PVC is deleted with the namespace; delete the PVC manually if the StatefulSet is removed alone (StatefulSets keep PVCs).
- Undo the branch deploy: `./bootstrap.sh up --env kodekloud` without `GITOPS_REVISION` (back to `main`).
- GHCR packages stay; delete in GitHub -> Packages if ever needed.
- End of session: `./bootstrap.sh down` (playground is wiped anyway; Git and GHCR are the durable state).

## 8. Concepts
- **Helm vs Kustomize.** Helm = templating plus a values schema: one chart serves 12 services, `values.schema.json` rejects bad input, and the interface is explicit. Cost: Go-template YAML is harder to read. Kustomize = patch plain YAML: transparent and no templating language, but 12 near-identical services would mean 12 bases or heavy patching, and there is no schema. We chose Helm because "one chart, many services" is the whole point; Kustomize would suit a single app with small per-env tweaks. They can combine, we did not need to.
- **Why `helm list` shows nothing.** Argo CD does not run `helm install`. It runs `helm template`, then applies the YAML itself (like `kubectl apply` with diffing, pruning and health). There is no Helm release Secret in the cluster; Git is the source of truth and Argo is the only writer. Analogy: Helm is the recipe, Argo is the chef who cooks and then compares the dish to the recipe forever. Production value: no second state store to drift, and rollbacks are `git revert`.
- **Why images are pinned by digest.** A tag (`v0.10.7`, `alpine`) is a movable label; a digest (`sha256:...`) is the content hash. Pulling by digest guarantees the same bytes on every node, in every environment, today and in a year, and tamper/replace is detectable. Analogy: tag = a name on a parcel, digest = the parcel's fingerprint. The schema enforces it so nobody sneaks in `:latest`.
- **GITHUB_TOKEN vs PAT for GHCR.** The built-in `GITHUB_TOKEN` is created per run, scoped by the workflow's `permissions:` (`packages: write`), expires when the run ends, and nothing is stored. Fine-grained PATs cannot push to GHCR (classic PATs can, but they are long-lived and broad). So CI pushes, never a laptop; the credential cannot leak because it does not exist outside the run.
- **Redis as StatefulSet, not Deployment.** A gp3 EBS volume is ReadWriteOnce: attachable to one node. A Deployment's RollingUpdate starts the new pod before stopping the old one; if they land on different nodes the new pod hits a Multi-Attach error and the rollout hangs. A StatefulSet stops the old pod first and gives each replica its own PVC. Trade-off: brief downtime on update (acceptable for a cart cache; for real data use replication).
- **Prefix delegation.** Normally each pod gets its own secondary IP from an ENI slot; a t3.medium has 3 ENIs x 6 IPs, giving 17 pods. With prefix delegation each slot holds a /28 (16 IPs), so ~110 pods fit. Analogy: instead of handing out single parking tickets, the car park hands out whole rows. Ordering matters: the kubelet's `maxPods` (nodes.tf) and the CNI mode must agree; if a node advertises 110 without prefix mode, pods schedule and then fail for lack of IPs. Hence the CNI patch runs first (Terraform dependency), and nodes must be replaced for the new `maxPods` to apply.
- **Draining and PodDisruptionBudgets.** `kubectl drain` evicts pods through the eviction API, which respects PDBs: coredns allows only one replica to be down, so the second eviction is refused until the first replacement is Ready elsewhere. That pause is the safety net that kept DNS up during the node rollout. Never force past a PDB in production; wait, or fix capacity. Rolling nodes one at a time, with the cluster healthy between each, is the manual equivalent of a surge-free rolling update.
- **Pod slots.** On EKS with the VPC CNI each pod needs an ENI IP; t3.medium allows 17 pods. Capacity planning must count pods, not just CPU/memory.
- **NetworkPolicy** is default-deny ingress with an allow list per service. It is only enforced if the CNI enables it (not yet here).

## 9. Interview questions
1. *Why pin images by digest instead of tag?* Tags are mutable; a digest identifies exact content, so deployments are reproducible and tampering is detectable.
2. *Why doesn't `helm list` show Argo-deployed charts?* Argo renders with `helm template` and applies manifests itself; no Helm release object exists. Git plus Argo is the state.
3. *A Deployment with an RWO volume hangs on rollout. Why, and the fix?* Multi-Attach: the new pod is scheduled while the old one holds the EBS volume. Use a StatefulSet (or `strategy: Recreate`).
4. *Why GITHUB_TOKEN rather than a PAT for pushing to GHCR?* Short-lived, per-run, scoped by `permissions:`, nothing to store or rotate; PATs are long-lived secrets.
5. *Your cluster has CPU left but pods stay Pending on small instances. Why?* Per-node pod limit from ENI/IP capacity (17 on t3.medium); check `kubectl describe node` allocatable pods.

## 10. Break it
1. **Mutable/unavailable image:** change a digest to a nonexistent one (or make the GHCR package private). Pods go `ImagePullBackOff`; Argo shows Degraded. Diagnose with `kubectl describe pod`, fix by restoring the digest/visibility.
2. **Multi-Attach hang:** change redis-cart back to a Deployment with an RWO PVC and roll it. Rollout stalls with `Multi-Attach error for volume`.
3. **Pod-slot exhaustion:** enable test + prod without trimming. New pods sit `Pending` with `Too many pods`; CPU graphs look healthy, which is the trap.

## Follow-ups
- **(a) Phase 3.5 - domain, TLS, SSO.** Buy a domain, then: hostnames as Gateway/HTTPRoute values (already planned as values, no rewrite), TLS via cert-manager (Let's Encrypt) on both entrances, SSO for Argo CD and Grafana (GitHub first; Entra ID or Keycloak optional), secrets via SOPS (scaffold exists). Until then both entrances are plain HTTP: a KNOWN GAP, mitigated only by the admin load balancer's source-IP allow-list.
- **(b) Personal-AWS production cluster - secrets.** Use AWS Secrets Manager with the External Secrets Operator, authenticated through IRSA or EKS Pod Identity. Never plain Kubernetes Secrets or values in Git. The chart already only *references* secrets (`secretRef`), so it needs no change.
