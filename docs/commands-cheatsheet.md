# Commands cheatsheet

Only commands verified to work. Grouped by tool; updated every phase.

## pre-commit

```bash
pip install --user pre-commit && export PATH=$HOME/.local/bin:$PATH
pre-commit install                  # enable hooks in this clone (once per clone)
pre-commit run --all-files          # scan the whole repo
pre-commit uninstall                # remove the hook
```

## gitleaks (via pre-commit)

```bash
./scripts/test-secret-block.sh      # prove a fake AWS key is blocked
```

AWS's documented `...EXAMPLE` keys are allowlisted and will NOT be flagged.

## git

```bash
git checkout -b feat/<name>                       # feature branch
git push -u origin feat/<name>                    # publish branch
git push origin <sha>:refs/heads/main             # one-time seed of an empty repo (owner-approved)
```

## gh

```bash
gh auth status
./scripts/setup-github.sh                 # idempotent branch protection on main (admins enforced, 0 approvals; needs main to exist)
gh api repos/pathfindersh/prod-drills-claude --jq '{default_branch,visibility}'
gh api repos/pathfindersh/prod-drills-claude/branches/main/protection \
  --jq '{enforce_admins: .enforce_admins.enabled, approvals: .required_pull_request_reviews.required_approving_review_count, pr_required: (.required_pull_request_reviews != null), force_push: .allow_force_pushes.enabled}'
```

## bootstrap.sh

```bash
./bootstrap.sh check                      # tools + min versions, install hints per OS
./bootstrap.sh up --env kodekloud         # confirm acct/region -> init -> plan -> confirm -> apply -> kubeconfig -> wait for nodes
./bootstrap.sh status                     # account, region, session minutes, cluster + nodes
./bootstrap.sh down --env kodekloud       # delete LB Services + PVCs, wait, terraform destroy, clean kubeconfig
```

`check`, `up --env kodekloud` (10m55s) and `down --env kodekloud` (5m06s) are verified end to end with no manual steps. `status` is not yet verified.

Exit codes of `bootstrap.sh` (check with `echo $?`):

| code | meaning |
|---|---|
| 0 | success (`down`: everything checked and nothing left behind) |
| 1 | stopped with a `STOP:` message, or a command failed (other non-zero codes can come straight from a failed tool) |
| 2 | usage error (unknown subcommand) |
| 3 | `down` finished, but the leftover check is NOT clean: something remains, or a check could not run. Read the warnings |

```bash
scripts/test-down.sh && scripts/test-leftover-check.sh   # offline stub tests for down (no AWS)
```

## aws

```bash
aws sts get-caller-identity                                  # account/identity check (before every action)
aws configure get region                                     # region used by bootstrap.sh (AWS_REGION wins)
aws ssm get-parameter --name /aws/service/eks/optimized-ami/1.37/amazon-linux-2023/x86_64/standard/recommended/image_id \
  --query Parameter.Value --output text                      # AL2023 EKS AMI id for a version
aws eks update-kubeconfig --name demo-eks --region $REGION   # add the cluster to ~/.kube/config
python3 -I -c "import boto3;c=boto3.client('eks',region_name='$REGION');[print(v['clusterVersion'],v['status']) for v in c.describe_cluster_versions(clusterType='eks',includeAll=True)['clusterVersions']]"
                                                             # list EKS versions + support status (AWS CLI 2.22 lacks describe-cluster-versions)
```

## terraform

```bash
cp infra/terraform/envs/kodekloud.backend.tf.example infra/terraform/backend.tf
terraform -chdir=infra/terraform init -reconfigure -backend-config="path=$PWD/infra/terraform/.state/$ACCT-$REGION.tfstate"
terraform -chdir=infra/terraform state list                  # resources Terraform tracks (31 for this lab)
terraform -chdir=infra/terraform plan -var-file=envs/kodekloud.tfvars -var "region=$REGION"
terraform -chdir=infra/terraform fmt -check && terraform -chdir=infra/terraform validate
```

Plan symbols: `+` create, `-` destroy, `~` update in place, `-/+` replace (check `forces replacement`).

## kubectl

```bash
kubectl config current-context            # must end with cluster/demo-eks
kubectl get nodes -o wide                 # 3 x Ready
kubectl get pods -n kube-system           # coredns, kube-proxy, aws-node (ebs-csi-* arrives in Phase 2)
```

## leftover checks (after `down`; independent of Terraform state)

```bash
aws eks list-clusters --region $REGION                                                   # {"clusters": []}
aws ec2 describe-instances --region $REGION --filters "Name=instance-state-name,Values=running,pending" \
  --query "Reservations[].Instances[].InstanceId"                                         # []
aws ec2 describe-volumes --region $REGION --filters "Name=status,Values=available" --query "Volumes[].VolumeId"   # []
aws elbv2 describe-load-balancers --region $REGION --query "LoadBalancers[].LoadBalancerName"                      # []
```

## terraform state surgery (manual; `bootstrap.sh down` now does this itself for listed resources)

```bash
cp infra/terraform/.state/$ACCT-$REGION.tfstate ~/tfstate-backup-$(date +%s).json
terraform -chdir=infra/terraform state rm 'aws_iam_policy.elb_ebs[0]'   # forget (NOT delete) a resource the playground won't let us delete
terraform -chdir=infra/terraform state list                              # empty when nothing is tracked
```

## helm / Argo CD (kubectl only; argocd CLI optional)

```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm search repo argo/argo-cd   # chart + version
kubectl get applications -n argocd                         # sync/health of every Argo app
kubectl describe application <name> -n argocd | tail -30   # why an app is stuck
kubectl port-forward svc/argocd-server -n argocd 8080:80   # Argo UI at http://localhost:8080
kubectl scale deploy ebs-csi-controller -n kube-system --replicas=3   # selfHeal demo: reverts in ~1s
GITOPS_REVISION=<branch> ./bootstrap.sh up --env kodekloud            # Argo follows a branch
```

## storage / load balancers (verified in Phase 2)

```bash
kubectl get sc                                             # default: gp2-csi (kodekloud), gp3 (personal) - gp2-csi not yet run on a cluster
kubectl get pv -o jsonpath='{.items[0].spec.csi.volumeHandle}'   # EBS volume id
aws ec2 describe-volumes --volume-ids <vol> --query 'Volumes[0].State' --output text   # InvalidVolume.NotFound after delete
aws elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text   # classic ELBs (in-tree provider)
```

## monitoring

```bash
kubectl top nodes                                          # metrics-server
kubectl describe nodes | grep -A8 "Allocated resources"    # requests vs allocatable (scheduler view)
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090
curl -s localhost:9090/api/v1/alerts | jq '.data.alerts[] | {alertname: .labels.alertname, state}'
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d   # Grafana admin password
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'          # OOMKilled? exitCode 137
```

## Phase 3 - application (verified 3a)
```bash
# helm / kubeconform
scripts/validate-charts.sh dev                                  # lint + template + kubeconform, every service
helm template frontend charts/microservice -f apps/online-boutique/frontend/values.yaml -f apps/online-boutique/frontend/values-dev.yaml

# GitHub Actions / GHCR
gh workflow run mirror-images.yml --ref main
gh run watch $(gh run list --workflow mirror-images.yml -L1 --json databaseId -q '.[0].databaseId')
skopeo inspect --raw docker://ghcr.io/pathfindersh/frontend:v0.10.7 | sha256sum   # anonymous digest check

# Argo / cluster
GITOPS_REVISION=feat/phase-3-application ./bootstrap.sh up --env kodekloud   # deploy a branch (re-point; omit var for main)
kubectl get applicationset -n argocd; kubectl get applications -n argocd
kubectl get pods,pvc -n shop-dev
kubectl -n shop-dev port-forward svc/frontend 8080:80
```

## Offline guards
```bash
scripts/check-no-ip.sh      # public repo: no real public IP or non-example /32 (needs network to detect your IP)
scripts/check-env-disk.sh   # kodekloud: gp2 only, node root volume <= 20GiB
scripts/test-no-ip.sh       # stub test of the IP guard
```
Both checks also run at the start of `scripts/validate-platform.sh`; the IP check also in `validate-charts.sh`.
