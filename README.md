# prod-drills-claude

A portable production-practice lab for DevOps/platform engineering. The repo is
the whole lab: on any machine, clone it and bring everything up with one
command. Built phase by phase; each phase has a write-up in `docs/phases/`.

Target environment: KodeKloud AWS playground (2h sessions, account wiped, max 3
EKS nodes, t3.medium or smaller, restricted IAM). Later: a personal AWS account.

> The repo is **public**. Never commit tokens, keys, passwords or kubeconfigs.
> A gitleaks pre-commit hook enforces this.

## Prerequisites

| Tool | Version used | Purpose |
|------|--------------|---------|
| git | 2.34+ | source control |
| gh (GitHub CLI) | 2.102 | PRs, repo settings |
| aws-cli | 2.22 | AWS access |
| terraform | 1.16 | infrastructure |
| kubectl | 1.36 | cluster access |
| jq | 1.6 | JSON parsing in bootstrap.sh |
| helm | 4.3 | chart installs |
| python3 + pip | 3.10+ | runs pre-commit |
| pre-commit | 4.6 | git hook framework |
| gitleaks | 8.30 | secret scanning (fetched by pre-commit, no manual install) |

### Ubuntu / WSL2

```bash
sudo apt-get update && sudo apt-get install -y git python3-pip curl unzip
pip install --user pre-commit          # ensure ~/.local/bin is on PATH
# gh:        https://github.com/cli/cli/blob/trunk/docs/install_linux.md
# aws-cli:   https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
# terraform: https://developer.hashicorp.com/terraform/install
# kubectl:   https://kubernetes.io/docs/tasks/tools/
# helm:      https://helm.sh/docs/intro/install/
```

### macOS

```bash
brew install git gh awscli terraform kubectl helm pre-commit
```

### Check your tools

```bash
git --version; gh --version; aws --version; terraform version
kubectl version --client; helm version --short; pre-commit --version
```

## Quickstart

```bash
gh auth login
git clone https://github.com/pathfindersh/prod-drills-claude.git
cd prod-drills-claude
pre-commit install                 # enable the secret-scanning hook (once per clone)
./bootstrap.sh check               # tools + minimum versions
./bootstrap.sh up --env kodekloud  # confirms account/region, then builds EKS (<= 30 min)
./bootstrap.sh status              # cluster + nodes + session timer
./bootstrap.sh down --env kodekloud  # deletes LBs/PVCs, then terraform destroy
```

Before touching any cloud resource, verify where you are:

```bash
aws sts get-caller-identity        # expected account/region?
kubectl config current-context     # this lab's cluster?
```

If either is wrong, stop.

## Storage

Phase 1 leaves the cluster **without a storage driver** (PVCs stay `Pending`). The EKS
addon could be created but not deleted in the KodeKloud playground, so Phase 2 installs
the EBS CSI driver with Helm via Argo CD (sync wave 0). The node role already carries
`AmazonEBSCSIDriverPolicy`.

## Moving to another machine

Everything needed is in the repo; nothing lives only on one laptop.

1. Install the prerequisites above.
2. `gh auth login`, then clone the repo and run `pre-commit install`.
3. Configure AWS credentials for the target account (KodeKloud sessions give
   fresh credentials each time; never save them in the repo).
4. Copy `envs/<env>.tfvars.example` to `envs/<env>.tfvars` and fill in values
   (gitignored).
5. `./bootstrap.sh up --env <env>`. Region comes from `AWS_REGION` or
   `aws configure get region`; `up` prints it and asks you to confirm.

Not in git by design: `*.tfstate`, `*.tfvars`, `.env`, kubeconfigs, `*.pem`,
age keys. Recreate or restore them per environment.

## Layout

| Path | Purpose |
|------|---------|
| `CLAUDE.md` | working rules for this lab |
| `docs/phases/` | one write-up per phase |
| `docs/commands-cheatsheet.md` | every verified command, by tool |
| `scripts/` | helper scripts (GitHub setup, hook test) |
| `bootstrap.sh` | `check` / `up` / `down` / `status` for the lab |
| `infra/terraform/` | EKS + IAM + nodes (adapted from KodeKloud, see `docs/third-party.md`) |
| `infra/terraform/envs/` | per-env tfvars and backend templates (`kodekloud` local state, `personal` S3) |
| `.pre-commit-config.yaml` | gitleaks secret scanning |
