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
./bootstrap.sh up --env kodekloud  # EKS + Argo CD; Argo then syncs platform/ from Git (App of Apps)
./bootstrap.sh status              # cluster + nodes + Argo app summary + session timer
./bootstrap.sh down --env kodekloud  # deletes LBs/PVCs, then terraform destroy
```

Before touching any cloud resource, verify where you are:

```bash
aws sts get-caller-identity        # expected account/region?
kubectl config current-context     # this lab's cluster?
```

If either is wrong, stop.

### GitOps note

`up` installs Argo CD with Helm, then applies `bootstrap/root.yaml`; everything under `platform/`
is synced from this repo (a **push to the tracked branch is a deploy**). To test a branch before
merging: `GITOPS_REVISION=<branch> ./bootstrap.sh up --env kodekloud`. Argo UI:
`kubectl port-forward svc/argocd-server -n argocd 8080:80`; Grafana:
`kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80`. Passwords are
generated at bootstrap and printed once. Details: `docs/phases/02-gitops-monitoring.md`.

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

## Secrets (SOPS + age)

Nothing real is stored yet; this is the scaffold for later.

- Runtime secrets are **generated at bootstrap** where possible: the Grafana admin password is
  random, lives only in the Kubernetes Secret `monitoring/grafana-admin`, and is printed once by
  `./bootstrap.sh up`.
- Persistent secrets (things that must survive a rebuild) will be committed **encrypted** with
  [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age): only the
  `data`/`stringData` values are encrypted, so diffs stay readable.
- Key handling: generate once with `age-keygen -o ~/.config/sops/age/keys.txt` (never commit it;
  `.gitignore` blocks `*.age`, `keys.txt`, `age.key`). Put the **public** recipient (`age1...`) in
  `.sops.yaml`. Provide the **private** key at use time through the environment:
  `export SOPS_AGE_KEY="$(cat ~/.config/sops/age/keys.txt)"`.
- Usage: `sops --encrypt --in-place secrets/foo.sops.yaml` / `sops --decrypt secrets/foo.sops.yaml`.
- `./bootstrap.sh check` only warns if `sops`/`age` are missing.
