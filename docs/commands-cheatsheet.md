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

`check`, the bad-`--env` error and `down` (needing two manual `state rm`s on the playground, see phase 1 doc) are verified. `up` end to end and `status` are not yet.

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
kubectl get pods -n kube-system           # coredns, kube-proxy, aws-node, ebs-csi-*
```

## leftover checks (after `down`; independent of Terraform state)

```bash
aws eks list-clusters --region $REGION                                                   # {"clusters": []}
aws ec2 describe-instances --region $REGION --filters "Name=instance-state-name,Values=running,pending" \
  --query "Reservations[].Instances[].InstanceId"                                         # []
aws ec2 describe-volumes --region $REGION --filters "Name=status,Values=available" --query "Volumes[].VolumeId"   # []
aws elbv2 describe-load-balancers --region $REGION --query "LoadBalancers[].LoadBalancerName"                      # []
```

## terraform state surgery (playground teardown only; back up first)

```bash
cp infra/terraform/.state/$ACCT-$REGION.tfstate ~/tfstate-backup-$(date +%s).json
terraform -chdir=infra/terraform state rm 'aws_eks_addon.ebs_csi[0]'   # forget (NOT delete) a resource the playground won't let us delete
terraform -chdir=infra/terraform state rm aws_iam_policy.elb_ebs
terraform -chdir=infra/terraform state list                              # empty when nothing is tracked
```
