# Phase 1 — Infrastructure provisioning (EKS with Terraform)

## 1. Goal

Create a portable, repeatable way to stand up and tear down the lab's Kubernetes
cluster. `bootstrap.sh` checks the tools, confirms the AWS account and region
with a human, runs Terraform to build an EKS cluster (control plane, IAM roles,
3 t3.medium worker nodes, EBS CSI driver), and tears everything down in an order
that leaves no orphaned AWS resources. The Terraform is adapted from KodeKloud's
playground-compatible code, because the playground's restricted IAM only accepts
specific role names and denies managed node groups. Sessions last 2 hours, so
`up` has a 30-minute budget and the tooling warns at 1h45m.

## 2. Architecture

```
 your machine                                   AWS account (default VPC, region from AWS_REGION)
┌───────────────────────────┐                 ┌─────────────────────────────────────────────────────┐
│ bootstrap.sh up|down      │  terraform      │  IAM: eksClusterRole  eksWorkerNodeRole  eksPolicy │
│  ├─ check tools           │ ──────────────► │                                                     │
│  ├─ confirm acct+region   │                 │  EKS control plane "demo-eks" (AWS-managed, 1.37)   │
│  └─ terraform             │                 │     ▲ 443 / 1025-65535 (SG rules both ways)         │
│                           │                 │     │                                               │
│ infra/terraform/.state/   │                 │  ASG node-asg (3x t3.medium, AL2023, public subnets │
│  <acct>-<region>.tfstate  │                 │   in AZs a,b,c)  ──► aws-auth ConfigMap lets the    │
│  (local, git-ignored)     │                 │   node role join                                    │
│                           │ ◄── kubectl ──► │  kube-system: coredns, kube-proxy, aws-node (CNI),  │
│ ~/.kube/config            │                 │               ebs-csi-controller / ebs-csi-node     │
└───────────────────────────┘                 └─────────────────────────────────────────────────────┘
```

## 3. What was built

| File / resource | Purpose |
|---|---|
| `bootstrap.sh` | `check` (tools + min versions + install hints), `up --env`, `down --env`, `status`; per-step timings; 1h45m session guard |
| `infra/terraform/versions.tf` | provider pins (aws ~> 6, kubernetes ~> 2.38), kubernetes provider wired to the new cluster; credit to KodeKloud |
| `infra/terraform/variables.tf` | `region` (no default), pinned `kubernetes_version`, playground-fixed names, node count 2–3 |
| `infra/terraform/data.tf` | default VPC, subnets in AZs a/b/c, AL2023 EKS AMI id from SSM |
| `infra/terraform/iam.tf` | `eksClusterRole`, `eksWorkerNodeRole`, `eksPolicy`, `NodeInstanceProfile` |
| `infra/terraform/eks.tf` | EKS cluster, `aws-auth` ConfigMap, `aws-ebs-csi-driver` addon |
| `infra/terraform/nodes.tf` | node security group + 7 SG rules (node/control-plane access), launch template (AL2023 + nodeadm), ASG |
| `infra/terraform/policy.yaml` | ELB + EBS permissions (from KodeKloud), attached to both roles |
| `infra/terraform/envs/kodekloud.tfvars` | playground values (version 1.37, t3.medium, 3 nodes) — no region |
| `infra/terraform/envs/kodekloud.backend.tf.example` | `backend "local" {}`; path supplied at init |
| `infra/terraform/envs/personal.*.example` | personal-account template with S3 backend + `use_lockfile` |
| `docs/third-party.md` | what we borrowed from KodeKloud and what we changed |
| `.gitignore` additions | `backend.tf`, `.state/`, `*.tfplan`, `.bootstrap/`; exception for `kodekloud.tfvars` |

Not built (deliberate): a VPC (the playground provides a default one and
creating one risks an IAM deny), managed node groups (denied by the playground),
SSH keys (use SSM instead).

## 4. Working commands

Verified in this session, in run order. Run from the repo root.

**Tool check and input validation**

```bash
./bootstrap.sh check
# ==> Checking tools (detected OS: ubuntu)
#   git ok 2.34.1 (>= 2.34) / aws ok 2.22.22 / terraform ok 1.16.4 / kubectl ok 1.36.4 / jq ok 1.6
# ==> All tools OK
./bootstrap.sh up --env bogus
# STOP: --env must be 'kodekloud' or 'personal'      (exit code 1)
```

**Pick the Kubernetes version** (newest in STANDARD support; the AWS CLI 2.22 has
no `describe-cluster-versions`, so call the API through boto3)

```bash
python3 -I -c "
import boto3
c=boto3.client('eks',region_name='$(aws configure get region)')
for v in c.describe_cluster_versions(clusterType='eks',includeAll=True)['clusterVersions']:
    print(v['clusterVersion'],v['status'],str(v.get('endOfStandardSupportDate'))[:10])
"
# 1.37 STANDARD_SUPPORT 2027-12-01   <- pinned in envs/kodekloud.tfvars
# 1.36 STANDARD_SUPPORT 2027-08-02
# ...
# 1.33 EXTENDED_SUPPORT 2026-07-29   (extended support costs extra)
aws ssm get-parameter --name /aws/service/eks/optimized-ami/1.37/amazon-linux-2023/x86_64/standard/recommended/image_id \
  --query Parameter.Value --output text
# ami-...   (the AL2023 AMI exists for the pinned version)
```

**Connect to the cluster and check it**

```bash
REGION=$(aws configure get region)
aws eks update-kubeconfig --name demo-eks --region $REGION
# Added new context arn:aws:eks:us-east-1:<acct>:cluster/demo-eks to ~/.kube/config
kubectl config current-context        # ends with cluster/demo-eks
kubectl get nodes -o wide
# 3 nodes, STATUS Ready, VERSION v1.37.1-eks-..., OS-IMAGE Amazon Linux 2023
kubectl get pods -n kube-system
# aws-node x3 (2/2), coredns x2, ebs-csi-controller x2 (6/6), ebs-csi-node x3 (3/3), kube-proxy x3 — all Running
```

**Move state from the legacy `-state` flag to a local backend** (no data copied: the
backend path is the same file the flag pointed at)

```bash
REGION=$(aws configure get region)
ACCT=$(aws sts get-caller-identity --query Account --output text)
STATE=infra/terraform/.state/$ACCT-$REGION.tfstate
cp $STATE ~/tfstate-backup-$(date +%s).json                         # backup first
terraform -chdir=infra/terraform state list -state=.state/$ACCT-$REGION.tfstate | wc -l   # 31
cp infra/terraform/envs/kodekloud.backend.tf.example infra/terraform/backend.tf
terraform -chdir=infra/terraform init -reconfigure -backend-config="path=$PWD/$STATE"
# Successfully configured the backend "local"!        (no "copy existing state?" prompt)
terraform -chdir=infra/terraform state list | wc -l                # 31 (same as before)
terraform -chdir=infra/terraform plan -var-file=envs/kodekloud.tfvars -var "region=$REGION"
```

**Teardown: two `down` runs (verified, but NOT yet clean in one command)**

Run 1 stopped on a denied `eks:DeleteAddon` (the EBS CSI addon). *The exact error text
and timings of this run were not captured; paste them here.* Recovery, then run 2:

```bash
REGION=$(aws configure get region); ACCT=$(aws sts get-caller-identity --query Account --output text)
cp infra/terraform/.state/$ACCT-$REGION.tfstate ~/tfstate-backup-predestroy-$(date +%s).json   # always back up before state surgery
terraform -chdir=infra/terraform state rm 'aws_eks_addon.ebs_csi[0]'     # state only; AWS untouched
# Removed aws_eks_addon.ebs_csi[0]
./bootstrap.sh down --env kodekloud
# ... destroys everything except eksPolicy, then:
# Error: deleting IAM Policy (arn:aws:iam::<acct>:policy/eksPolicy): ... api error AccessDenied:
#   User: arn:aws:iam::<acct>:user/kk_labs_user_683130 is not authorized to perform:
#   iam:DeletePolicy ... because no identity-based policy allows the iam:DeletePolicy action
terraform -chdir=infra/terraform state rm aws_iam_policy.elb_ebs
terraform -chdir=infra/terraform state list                  # no output: state empty
```

Leftover checks after run 2 (all clean):

```bash
aws eks list-clusters --region us-east-1                      # {"clusters": []}
aws ec2 describe-instances --region us-east-1 --filters "Name=instance-state-name,Values=running,pending"   --query "Reservations[].Instances[].InstanceId"             # []
aws ec2 describe-volumes --region us-east-1 --filters "Name=status,Values=available" --query "Volumes[].VolumeId"   # []
aws elbv2 describe-load-balancers --region us-east-1 --query "LoadBalancers[].LoadBalancerName"                      # []
```

Timings, `down` run 2 (from the script's own output, region `us-east-1`):

| Step | Time |
|---|---|
| point kubectl at cluster | 1s |
| delete LoadBalancer Services (none existed) | 2s |
| delete PVCs (`No resources found`) | 3s |
| wait for load balancers to disappear | 5s |
| `terraform init` | 3s (16s elapsed so far) |
| destroy: Auto Scaling Group (3 nodes) | 1m29s |
| destroy: EKS control plane | 2m26s |
| destroy: node role, profile, SG, launch template, cluster role, attachments | seconds each |
| `iam:DeletePolicy` on `eksPolicy` | AccessDenied: run aborted (no "destroy took" line, no kubeconfig cleanup) |

Roughly 4 minutes from start to the error (derived from the lines above, not measured end to end).

**Not yet verified (honest status):**

- A `down` that finishes with no manual `state rm`. Both runs needed one. This is the
  open design item (see section 7 and the PR).
- `./bootstrap.sh up` end to end, and its 30-minute budget. The cluster was built by
  hand with the legacy `-state` flag; the new-backend `apply` path was never run.
- The post-fix `terraform plan` ("No changes.") was not confirmed before teardown.
- The 1h45m session reminder (no session was started with `up`).
- `eksPolicy` still exists in the account (state no longer tracks it). A second
  `up` in the *same* account would fail with `EntityAlreadyExists`. The playground wipes
  the account between sessions, so this only matters within one session.

## 5. Problems hit and fixes

| Error message | Root cause | Command that failed | Command that worked | Lesson |
|---|---|---|---|---|
| `InvalidParameterValue: Invalid rule description. Valid descriptions are strings ... from the following set: a-zA-Z0-9. _-:/()#,@[]+=&;{}!$*` (5 SG rules; apply stopped partway) | EC2 security-group rule descriptions allow only that character set; the `>` in `->` is not in it. | `terraform apply` with `description = "Control plane -> kubelet and pods"` | `terraform apply` after changing to `"Control plane to kubelet and pods"` (only descriptions changed) | `validate` and `plan` cannot see AWS-side field rules; only `apply` does. Keep descriptions plain ASCII. A partial apply is safe to re-run: state records what exists. |
| Plan drift: `authentication_mode = "API_AND_CONFIG_MAP" -> "CONFIG_MAP"` (`Plan: 0 to add, 1 to change`) | The code asked for `CONFIG_MAP`, but EKS reported `API_AND_CONFIG_MAP` on the 1.37 cluster. Auth mode is one-way (`CONFIG_MAP` → `API_AND_CONFIG_MAP` → `API`), so the plan was asking for a downgrade EKS does not offer (not applied; we did not test what the API would answer). | `terraform plan` with `authentication_mode = "CONFIG_MAP"` | `terraform plan` after setting `authentication_mode = "API_AND_CONFIG_MAP"` (code now matches reality; `aws-auth` unchanged) | When reality moves one-way, change the code, not reality. Read the arrow: `old -> new` is "what AWS has -> what your code wants". |
| `aws: error: argument operation: Invalid choice` for `aws eks describe-cluster-versions` | Installed AWS CLI 2.22.22 predates that subcommand. | `aws eks describe-cluster-versions ...` | `python3 -I -c "import boto3 ... describe_cluster_versions(...)"` (boto3 1.35.49 already had it) | Same API, different client. Upgrade the CLI when convenient; check `aws <svc> help` before trusting a command exists. |
| `-state` is "a legacy option used for the local backend only" (`terraform plan -help`) | Passing a state file per command is the old interface; the supported way is backend configuration. Also, my first plan command hardcoded `us-east-1` in the state file name. | `terraform plan ... -state=.state/$ACCT-us-east-1.tfstate` | `terraform init -reconfigure -backend-config="path=…/$ACCT-$REGION.tfstate"`, then plain `terraform plan` | Choose the backend once at init, not per command. Derive account and region from variables, never type them. |
| `eks:DeleteAddon` denied during `down` (run 1; exact text not captured) | The playground allows creating the `aws-ebs-csi-driver` addon but denies deleting it, and Terraform deletes the addon before the cluster. | `./bootstrap.sh down --env kodekloud` | `terraform state rm 'aws_eks_addon.ebs_csi[0]'`, then `./bootstrap.sh down` again (cluster deletion removes the addon) | Create and delete are separate permissions. Do not assume a resource that applies cleanly can be destroyed. `state rm` forgets a resource; it does not delete it. |
| `AccessDenied ... not authorized to perform: iam:DeletePolicy on resource: policy .../eksPolicy because no identity-based policy allows the iam:DeletePolicy action` (run 2) | Same pattern: the playground allows `CreatePolicy`, denies `DeletePolicy`. Detaching the policy and deleting both roles worked. | `./bootstrap.sh down --env kodekloud` (the `terraform destroy` step) | `terraform state rm aws_iam_policy.elb_ebs`; leftover checks then clean | A custom managed policy cannot be removed here, so it should not be Terraform-managed in this env. Teardown must be tested the same way as setup. |

## 6. How to verify

```bash
aws sts get-caller-identity                          # expected account
kubectl config current-context                       # ends with cluster/demo-eks
kubectl get nodes                                    # 3 x Ready, v1.37.x
kubectl get pods -n kube-system                      # all Running, incl. ebs-csi-*
terraform -chdir=infra/terraform plan -var-file=envs/kodekloud.tfvars -var "region=$(aws configure get region)"
                                                     # "No changes." — no drift
./bootstrap.sh status                                # cluster ACTIVE + nodes
```

After `down`, nothing billable should remain (commands in section 4):
no clusters, no running instances, no `available` volumes, no load balancers.

Optional storage check (creates and removes a 1 GiB EBS volume): create a PVC
using a StorageClass backed by `ebs.csi.aws.com`, attach it to a pod, confirm
`Bound`, then delete both. (Not run in this phase.)

## 7. Rollback / teardown

```bash
./bootstrap.sh down --env kodekloud
```

Order, and why:

1. Delete every `Service` of type `LoadBalancer`. Cloud load balancers are created
   by a controller inside the cluster, not by Terraform. If the cluster is
   destroyed first, the ELB lives on (and bills), and its ENIs and security-group
   references block deletion of the SGs and VPC objects Terraform does own.
2. Delete PVCs, and wait for the PVs to disappear. Same reason: EBS volumes are
   created by the CSI driver, outside Terraform's state, so `destroy` never sees
   them. Deleting the PVC while the driver still runs makes it delete the volume.
3. Wait until no load balancer remains in the VPC.
4. `terraform destroy`.
5. Remove the dead kubeconfig entries.

`down` stops with a message if PVCs are still in use (a pod holds them); delete
the owning workload and run `down` again — it is idempotent. On the playground the
account is wiped after the session anyway, but a personal account keeps billing
for an EKS control plane (~$0.10/h) and nodes until destroyed.

**Known problem (not yet fixed): `down` is not one command on the playground.**
`eks:DeleteAddon` and `iam:DeletePolicy` are denied, so `terraform destroy` stops at
those resources and each needed a manual `terraform state rm`. Everything billable
(cluster, instances, volumes, load balancers) was gone after the runs; the orphaned
objects are the addon (removed with the cluster) and the `eksPolicy` IAM policy
(free, left in the account until it is wiped). A permanent fix is proposed in PR #3
and is not implemented yet. Never run `state rm` before confirming with the leftover
checks that the real resource is gone or free.

## 8. Concepts

**Terraform state and why its location matters.** State is Terraform's memory of
which real resources belong to this config. *Analogy:* the inventory book of a
warehouse — lose it and you cannot tell what you own, so you duplicate or orphan
things. Local state lives on one laptop: use another machine (or a wiped
playground account) and Terraform believes nothing exists. That is why local state
is acceptable only for the disposable KodeKloud env, keyed by account+region so a
new account never inherits old state. A real environment needs remote state
(S3 here) so every machine and teammate sees the same book, with locking
(`use_lockfile`, S3-native, Terraform ≥ 1.10) so two applies cannot write at once
and corrupt it. In production, state also contains secrets, so the bucket must be
private, encrypted and versioned.

**Reading a plan.** `+` create, `-` destroy, `~` update in place, `-/+` destroy
then create (look for `# forces replacement` — on a database or a node role that
means an outage). `(known after apply)` is an ID AWS has not assigned yet. For an
attribute, `old -> new` means "AWS has `old`, your code says `new`".

**Drift.** Drift is when the real world differs from what Terraform last recorded
or what the code says. *Analogy:* someone rearranged the warehouse shelves after
you wrote the inventory. `terraform plan` detects it in two steps: it *refreshes*
(asks AWS for the current attributes of every resource in state), then *compares*
that with the code; any difference becomes a planned change. Here the drift was
not a person: EKS itself set the auth mode. In production, unexplained drift means
someone changed things by hand or another tool is fighting Terraform; a scheduled
`plan` that alerts on drift catches it early.

**One-way auth mode.** An EKS cluster's `authentication_mode` can only move
forward: `CONFIG_MAP` → `API_AND_CONFIG_MAP` → `API`. It cannot go back, because
lowering it would instantly lock out any principal granted through the newer
mechanism. So when Terraform and EKS disagreed, the only valid fix was to change
the code to match. Treat one-way settings as decisions you make once, in code
review, before the first apply.

**`aws-auth` ConfigMap vs EKS access entries.** Both answer "which IAM identities
may use this cluster, and as what?"

- *`aws-auth` ConfigMap:* a YAML ConfigMap in `kube-system` mapping IAM role ARNs
  to Kubernetes users/groups. Nodes join by mapping the node role to
  `system:bootstrappers` and `system:nodes`. It is just a Kubernetes object, so a
  bad edit (or a deleted ConfigMap) can lock everyone out, including you, with no
  AWS-side audit trail. *Analogy:* a paper guest list taped to the door, edited
  by anyone with a pen.
- *Access entries (API auth mode):* the mapping lives in the EKS API
  (`aws eks create-access-entry`), managed with IAM permissions, logged in
  CloudTrail, and recoverable even if the cluster is unreachable. Includes AWS
  managed access policies. *Analogy:* a badge system with an audit log.
- *Why ConfigMap here:* KodeKloud's playground-proven recipe joins unmanaged nodes
  through `aws-auth`, and in this lab it is the smallest working change. The
  cluster is in `API_AND_CONFIG_MAP`, which honours both, so it is also the
  migration path.
- *Production:* new clusters should use access entries (`API` mode) and not
  create `aws-auth` at all.

**Known gaps (lab shortcuts, not for production):**

- **Nodes are in public subnets** with public IPs (default VPC). Fine for a
  disposable lab; production runs nodes in *private* subnets with egress through
  NAT gateways (or VPC endpoints), and only load balancers in public subnets.
- **`aws-auth` instead of access entries** (above).
- **EKS API endpoint is public** (default). Production restricts it by CIDR or
  makes it private.
- **No control-plane logging, no encryption of Kubernetes secrets with KMS.**
- **Node IAM is broad:** `eksPolicy` (ELB + EBS) sits on the node role so any pod
  can use it via IMDS. Production uses IRSA or EKS Pod Identity per workload.
- **No instance refresh:** changing the launch template does not roll nodes (it
  would exceed the 3-node cap); nodes are replaced manually.
- **Single local state file** for the playground env.
- **Cluster support policy:** the cluster was created with EKS's default
  `upgrade_policy.support_type = "EXTENDED"` (seen in the destroy plan), which bills
  extra after standard support ends. Not yet set to `STANDARD` in code.
- **`down` needs manual `state rm`** for the addon and `eksPolicy` (section 7).

**Destroy permissions differ from create, so teardown must be tested.** IAM treats
`Create*` and `Delete*` as separate actions, and restricted accounts often allow one
without the other (here: create addon/policy yes, delete no). *Analogy:* a hotel
keycard that opens the door to check in but not the door to check out. The setup
works, everything looks fine, and the problem only appears at the end, when you are
tired and the clock is running. In production the same trap shows up as CI roles that
can deploy but not roll back, or `terraform destroy` failing halfway and leaving
billable resources. So: run `up` then `down` in a fresh account early, check for
leftovers with independent commands (not Terraform's own state), and design
resources so their teardown only needs actions you know are allowed.

**Unmanaged node group.** Instead of EKS-managed nodes, we run our own launch
template + Auto Scaling Group because the playground denies managed node groups.
We own AMI choice, join config (AL2023 `nodeadm` NodeConfig user-data) and
upgrades. In production prefer managed node groups (or Karpenter): AWS handles
draining and AMI rollouts.

**IMDSv2 with hop limit 2.** The instance metadata service hands out the node
role's credentials. IMDSv2 requires a session token (blocks simple SSRF theft).
Hop limit 2 lets pods (one network hop further) reach it — the EBS CSI controller
relies on this. Production moves to per-pod identities so pods need not reach
node credentials at all.

**Playground naming rules.** Cluster `demo-eks` and the IAM names are fixed
because the playground's IAM policy allows only those names. Lesson: restricted
accounts are configured by naming conventions as much as by permissions.

## 9. Interview questions

1. **Why must `terraform destroy` be preceded by deleting LoadBalancer Services and PVCs?**
   Those AWS resources are created by in-cluster controllers, so they are not in
   Terraform state. Destroying first leaves the ELBs and EBS volumes running and
   billing, and the ELB's ENIs/security-group references block deletion of the VPC
   pieces. Deleting while the controllers still run lets the cluster clean up.
2. **`terraform plan` shows a change you didn't make. What is it and what do you do?**
   Drift: the refreshed real state differs from code. Find out why (manual edit,
   AWS defaulting, another tool). If it is wanted or unrevertable, update the code
   to match; otherwise apply to restore. Never apply blindly: read `-/+` and
   `forces replacement` first.
3. **Why does state location matter across machines, and what protects it?**
   State is the source of truth for what exists; local state is invisible to
   other machines and lost with the laptop. Use remote state (S3) with versioning,
   encryption, restricted access and locking (S3 `use_lockfile`) so concurrent
   applies cannot corrupt it.
4. **`aws-auth` ConfigMap vs access entries — which and why?**
   `aws-auth` is a Kubernetes object, easy to break and unaudited. Access entries
   live in the EKS API, are IAM-controlled and CloudTrail-logged, and survive a
   broken cluster. New clusters use access entries; ConfigMap is legacy and a
   migration step. Auth mode moves only forward.
5. **Why not put worker nodes in public subnets in production?**
   Public IPs and a wider attack surface. Use private subnets, NAT/VPC endpoints
   for egress, public subnets only for load balancers, and security groups to
   restrict node access. The lab accepts the risk because it is disposable.

## 10. Break it

1. **Join failure / lockout via `aws-auth`.** Delete or corrupt the
   `kube-system/aws-auth` ConfigMap (`kubectl delete cm aws-auth -n kube-system`):
   new nodes cannot join and role-based access vanishes. Detect with `kubectl get
   nodes` (NotReady/missing nodes) and node logs; recover by re-applying the
   ConfigMap (or access entries) as the cluster creator.
2. **Orphaned resources on teardown.** Create a `Service type=LoadBalancer` and a
   PVC, then run `terraform destroy` directly (skipping `bootstrap.sh down`). The
   destroy hangs or fails on security groups/subnets in use; ELB and EBS volume
   remain in the account. Find them with `aws elbv2 describe-load-balancers` and
   `aws ec2 describe-volumes`.
3. **Drift and one-way settings.** Change something by hand (e.g. add a tag or
   change the node count in the ASG console), run `terraform plan`, and read the
   drift. Then try to lower `authentication_mode` and observe EKS refuse it.
   Also: kill the state file (`.state/…tfstate`) and watch Terraform plan to
   re-create everything that already exists.
