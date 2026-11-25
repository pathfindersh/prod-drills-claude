#!/usr/bin/env bash
# bootstrap.sh - bring the lab up/down from any machine.
#   ./bootstrap.sh check
#   ./bootstrap.sh up   --env <kodekloud|personal>
#   ./bootstrap.sh down --env <kodekloud|personal>
#   ./bootstrap.sh status [--env <env>]
# All subcommands are idempotent. `up` = terraform + Argo CD (helm) + root App of Apps;
# Argo then syncs everything under platform/ from Git. Set GITOPS_REVISION=<branch> to make
# Argo follow a branch other than main (testing before merge).
# Exit codes: 0 ok; 1 stopped (STOP: message) or a command failed; 2 usage error;
# 3 `down` finished but the leftover check is NOT clean.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$ROOT/infra/terraform"
STATE_DIR="$TF_DIR/.state"           # kodekloud: one local state file per AWS account
RUN_DIR="$ROOT/.bootstrap"           # git-ignored session bookkeeping
CLUSTER_NAME="demo-eks"              # must match var.cluster_name (playground-fixed)
SESSION_LIMIT_MIN=120
WARN_AT_MIN=105                      # 1h45m
UP_BUDGET_MIN=30

# ---------- helpers ----------
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_off=$'\e[0m'
info() { echo "${c_grn}==>${c_off} $*"; }
warn() { echo "${c_ylw}WARN:${c_off} $*" >&2; }
die()  { echo "${c_red}STOP:${c_off} $*" >&2; exit 1; }

STEP_T0=0
step_start() { STEP_T0=$SECONDS; info "$1"; }
step_done()  { printf '    %s took %ds (total %dm%02ds)\n' "$1" "$((SECONDS-STEP_T0))" "$((SECONDS/60))" "$((SECONDS%60))"; }

# version_ge A B -> true if A >= B (dotted versions)
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

os_id() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)  . /etc/os-release 2>/dev/null; echo "${ID:-linux}" ;;
    *)      echo other ;;
  esac
}

# ---------- check ----------
# tool | min version | version command | brew | apt/generic hint
TOOLS=(
  "git|2.34|git --version|brew install git|sudo apt-get install -y git"
  "aws|2.15|aws --version|brew install awscli|https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  "terraform|1.10|terraform version|brew install terraform|https://developer.hashicorp.com/terraform/install"
  "kubectl|1.30|kubectl version --client|brew install kubectl|https://kubernetes.io/docs/tasks/tools/"
  "jq|1.6|jq --version|brew install jq|sudo apt-get install -y jq"
  "helm|3.12|helm version --short|brew install helm|https://helm.sh/docs/intro/install/  (curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash)"
)
# Optional: only a warning when missing/old. Nothing in up/down/YOU RUN steps needs them.
OPT_TOOLS=(
  "argocd|2.10|argocd version --client --short|brew install argocd|https://argo-cd.readthedocs.io/en/stable/cli_installation/"
  "sops|3.8|sops --version|brew install sops|https://github.com/getsops/sops/releases (download the sops-vX.Y.Z.linux.amd64 binary)"
  "age|1.1|age --version|brew install age|sudo apt-get install -y age"
)

extract_ver() { grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1; }

cmd_check() {
  local os; os="$(os_id)"; local bad=0
  info "Checking tools (detected OS: $os)"
  local row name min vcmd brew other have
  for row in "${TOOLS[@]}"; do
    IFS='|' read -r name min vcmd brew other <<<"$row"
    if ! command -v "$name" >/dev/null 2>&1; then
      printf '  %-10s MISSING (need >= %s)\n' "$name" "$min"; bad=1
    else
      have="$($vcmd 2>&1 | extract_ver || true)"
      if [ -n "$have" ] && version_ge "$have" "$min"; then
        printf '  %-10s ok      %s (>= %s)\n' "$name" "$have" "$min"; continue
      fi
      printf '  %-10s TOO OLD %s (need >= %s)\n' "$name" "${have:-?}" "$min"; bad=1
    fi
    if [ "$os" = macos ]; then echo "      install: $brew"; else echo "      install: $other"; fi
  done
  for row in "${OPT_TOOLS[@]}"; do
    IFS='|' read -r name min vcmd brew other <<<"$row"
    if ! command -v "$name" >/dev/null 2>&1; then
      warn "optional tool '$name' missing (need >= $min)"
    else
      have="$($vcmd 2>&1 | extract_ver || true)"
      if [ -n "$have" ] && version_ge "$have" "$min"; then printf '  %-10s ok      %s (optional)\n' "$name" "$have"; continue; fi
      warn "optional tool '$name' is old: ${have:-?} (want >= $min)"
    fi
    if [ "$os" = macos ]; then echo "      install: $brew" >&2; else echo "      install: $other" >&2; fi
  done
  [ "$bad" = 0 ] && info "All required tools OK" || die "Fix the tools above, then re-run: ./bootstrap.sh check"
}

# ---------- session timer ----------
session_start_file="$RUN_DIR/session_start"
session_mark() { # start the clock once; re-running up must not reset it (stale marks >2h are replaced)
  mkdir -p "$RUN_DIR"
  if [ ! -f "$session_start_file" ] || [ "$(session_elapsed_min)" -ge "$SESSION_LIMIT_MIN" ]; then
    date +%s >"$session_start_file"
  fi
}
session_elapsed_min() {
  [ -f "$session_start_file" ] || { echo 0; return; }
  echo $(( ($(date +%s) - $(cat "$session_start_file")) / 60 ))
}
session_guard() { # $1 = "block" to refuse when past the warning mark
  local m; m="$(session_elapsed_min)"
  if [ "$m" -ge "$WARN_AT_MIN" ]; then
    echo "${c_red}!! ${m} min into a ${SESSION_LIMIT_MIN}-min session. Commit and push your work NOW, then run: ./bootstrap.sh down --env <env>${c_off}" >&2
    [ "${1:-}" = block ] && die "Refusing to start new work this late in the session."
  fi
}
start_reminder() { # detached timer that nags the terminal at the warning mark
  local left=$(( (WARN_AT_MIN - $(session_elapsed_min)) * 60 ))
  [ "$left" -gt 0 ] || return 0
  [ -w /dev/tty ] || return 0
  ( sleep "$left"; printf '\n\a%s!! 1h45m reached: git push your work, then ./bootstrap.sh down --env <env>%s\n' "$c_red" "$c_off" >/dev/tty ) \
    >/dev/null 2>&1 &
  disown || true
}

# ---------- aws / terraform context ----------
ENV_NAME=""; REGION=""; ACCOUNT=""; TFVARS=""

parse_env() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --env) ENV_NAME="${2:-}"; shift 2 ;;
      --env=*) ENV_NAME="${1#*=}"; shift ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
  case "$ENV_NAME" in
    kodekloud|personal) ;;
    *) die "--env must be 'kodekloud' or 'personal'" ;;
  esac
  TFVARS="$TF_DIR/envs/$ENV_NAME.tfvars"
  [ -f "$TFVARS" ] || die "Missing $TFVARS (copy envs/$ENV_NAME.tfvars.example)"
}

resolve_region() {
  REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
  [ -n "$REGION" ] || die "No region: set AWS_REGION or run 'aws configure set region <r>'"
}

confirm_identity() { # prints account/region and asks for yes
  local ident
  ident="$(aws sts get-caller-identity --output json)" || die "aws sts get-caller-identity failed (no/expired credentials?)"
  ACCOUNT="$(jq -r .Account <<<"$ident")"
  echo
  echo "  Account : $ACCOUNT"
  echo "  Identity: $(jq -r .Arn <<<"$ident")"
  echo "  Region  : $REGION"
  echo "  Env     : $ENV_NAME"
  echo
  read -r -p "Is this the right account and region for '$1'? Type 'yes' to continue: " ans
  [ "$ans" = yes ] || die "Not confirmed."
}

tf() { terraform -chdir="$TF_DIR" "$@"; }  # backend (local path or S3) is chosen at init

tf_init() {
  mkdir -p "$STATE_DIR"
  # Every env copies its backend block into backend.tf (git-ignored) and inits with
  # -reconfigure, so switching env/account/region never reuses a stale backend.
  cp "$TF_DIR/envs/$ENV_NAME.backend.tf.example" "$TF_DIR/backend.tf"
  if [ "$ENV_NAME" = personal ]; then
    [ -f "$TF_DIR/envs/personal.backend.hcl" ] || die "Missing envs/personal.backend.hcl (copy the .example)"
    tf init -input=false -reconfigure -backend-config=envs/personal.backend.hcl
  else
    # one local state file per account+region: a wiped playground never inherits old state
    tf init -input=false -reconfigure -backend-config="path=$STATE_DIR/$ACCOUNT-$REGION.tfstate"
  fi
}

kube_ctx_ok() { # current context must be this lab's cluster
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || true)"
  [[ "$ctx" == *"/$CLUSTER_NAME" || "$ctx" == "$CLUSTER_NAME" ]]
}

# ---------- argo cd ----------
# OCI, not the https chart repo: the https index points tarballs at GitHub release assets,
# which time out on some networks. ghcr.io is a different host. Same chart, same version.
ARGOCD_CHART_OCI="oci://ghcr.io/argoproj/argo-helm/argo-cd"
argocd_chart_version() { # single source of truth: platform/apps/values.yaml
  sed -n 's/^ *argocd: .*version: *\([0-9][0-9.]*\).*/\1/p' "$ROOT/platform/apps/values.yaml"
}

# JSON of all Applications -> "name sync health" lines
argo_app_rows() {
  kubectl get applications -n argocd -o json 2>/dev/null \
    | jq -r '.items[] | "\(.metadata.name) \(.status.sync.status // "?") \(.status.health.status // "?")"'
}

# Grafana admin password: random, lives ONLY in a Kubernetes Secret (never in Git).
# Created before Argo syncs the monitoring app, which references it via grafana.admin.existingSecret.
GRAFANA_PW_NEW=""
ARGO_INSTALLED_NOW=0   # set when THIS run did the helm install: only then is the Argo password "new"
grafana_secret() {
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  if kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
    info "secret monitoring/grafana-admin already exists (kept)"; return 0
  fi
  GRAFANA_PW_NEW="$(openssl rand -hex 16)"
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$GRAFANA_PW_NEW" >/dev/null
  info "created secret monitoring/grafana-admin"
}

# What to do about the Helm release "argocd": skip | install | reinstall:<status> | ERROR:<msg>.
# Only a release in status "deployed" may be skipped. A failed/pending release (e.g. the first install
# timed out) still exists, so "helm status" succeeds, but nothing usable was installed: skipping it
# left the cluster without the Application CRD and root.yaml failed. Absent release -> install.
argo_helm_action() {
  local out st
  if out="$(helm status argocd -n argocd -o json 2>&1)"; then
    st="$(jq -r .info.status <<<"$out")"
    if [ "$st" = deployed ]; then echo skip; else echo "reinstall:$st"; fi
  elif grep -qi "release: not found" <<<"$out"; then
    echo install
  else
    echo "ERROR:$out"
  fi
}

# The admin entrance allow-list: ADMIN_CIDR if set, else this machine's public IP as /32.
# Prints nothing if it cannot be determined or is not a /16../32 IPv4 CIDR: the admin load balancer is
# then NOT created (fail closed). Never written to any file in the repo.
detect_admin_cidr() {
  local c="${ADMIN_CIDR:-}"
  if [ -z "$c" ]; then
    c="$(curl -fsS --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
    [ -n "$c" ] && c="$c/32"
  fi
  if grep -Eqx '((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])/(1[6-9]|2[0-9]|3[0-2])' <<<"$c"; then
    echo "$c"
  fi
}

# root.yaml with the branch, environment and admin CIDR filled in (the committed file stays generic).
render_root() { # rev env cidr
  sed -e "/GITOPS_REV/ s|: main #|: $1 #|" \
      -e "/LAB_ENV/ s|values-kodekloud\.yaml|values-$2.yaml|" \
      -e "/ADMIN_CIDR/ s|value: \"\"|value: \"$3\"|" "$ROOT/bootstrap/root.yaml"
}

argo_install() {
  local ver; ver="$(argocd_chart_version)"; [ -n "$ver" ] || die "cannot read argocd chart version from platform/apps/values.yaml"
  # Once installed, Argo manages its own Helm release from Git, so re-running the install adds
  # nothing (and would needlessly depend on the network). Install only the first time.
  local act; act="$(argo_helm_action)"
  case "$act" in
    ERROR:*) die "cannot read the Helm release state of argocd: ${act#ERROR:}" ;;
    skip) info "Argo CD release 'argocd' is deployed - skipping helm install (Argo self-manages)" ;;
    reinstall:*)
      warn "Helm release 'argocd' is in status '${act#reinstall:}' (not deployed): uninstalling it and installing fresh"
      helm uninstall argocd -n argocd --wait --timeout 5m
      act=install ;;
  esac
  if [ "$act" = install ]; then
    step_start "helm install Argo CD chart $ver from OCI (same values file Argo later uses to manage itself)"
    helm upgrade --install argocd "$ARGOCD_CHART_OCI" --version "$ver" \
      --namespace argocd --create-namespace -f "$ROOT/platform/values/argocd.yaml" --wait --timeout 8m
    step_done "argocd helm"
    ARGO_INSTALLED_NOW=1
  fi

  grafana_secret

  step_start "apply bootstrap/root.yaml (App of Apps)"
  local rev="${GITOPS_REVISION:-main}" cidr
  [ "$rev" = main ] || warn "Argo will follow branch '$rev' instead of main (GITOPS_REVISION)"
  [ -f "$ROOT/platform/apps/values-$ENV_NAME.yaml" ] || die "platform/apps/values-$ENV_NAME.yaml missing"
  cidr="$(detect_admin_cidr)"
  if [ -n "$cidr" ]; then info "admin entrance allow-list: $cidr (plus gateway.admin.extraCidrs)"
  else warn "no valid public IP / ADMIN_CIDR: the admin load balancer will NOT be created (unless extraCidrs is set)"; fi
  render_root "$rev" "$ENV_NAME" "$cidr" | kubectl apply -f -
  step_done "root app"
}

argo_wait() { # all apps Synced+Healthy, root operation finished
  local timeout_min="${ARGO_WAIT_MIN:-20}" i rows bad
  step_start "waiting for all Argo apps Synced+Healthy (timeout ${timeout_min}m)"
  for i in $(seq 1 $((timeout_min*6))); do
    rows="$(argo_app_rows || true)"
    bad="$(awk '$2!="Synced" || $3!="Healthy"' <<<"$rows")"
    if [ "$(wc -l <<<"$rows")" -gt 1 ] && [ -z "$bad" ] \
       && [ "$(kubectl get application root -n argocd -o jsonpath='{.status.operationState.phase}' 2>/dev/null)" = Succeeded ]; then
      echo "$rows" | column -t; step_done "argo apps"; return 0
    fi
    sleep 10
  done
  echo "$rows" | column -t
  die "Argo apps not all Synced+Healthy after ${timeout_min}m. Inspect: kubectl get applications -n argocd ; kubectl describe application <name> -n argocd"
}

argo_howto() {
  echo
  info "Argo CD UI:  kubectl port-forward svc/argocd-server -n argocd 8080:80   ->  http://localhost:8080/argocd"
  local pw=""
  [ "$ARGO_INSTALLED_NOW" = 1 ] && pw="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
  if [ -n "$pw" ]; then
    echo "    user: admin   password (generated by Argo, shown once, never stored in Git): $pw"
  else
    echo "    read it again: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
  fi
  info "Grafana UI:  kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80  ->  http://localhost:3000/grafana/"
  info "Entrances (plain HTTP): public = shop at / /dev/ /test/ ; admin = /argocd/ /grafana/ (allow-listed IPs only)"
  kubectl get gateway -n envoy-gateway-system 2>/dev/null || true
  if [ -n "$GRAFANA_PW_NEW" ]; then
    echo "    user: admin   password (random, shown once, stored only in Secret monitoring/grafana-admin): $GRAFANA_PW_NEW"
  else
    echo "    read it again: kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d"
  fi
}

# ---------- up ----------
cmd_up() {
  parse_env "$@"; resolve_region
  cmd_check
  session_mark; session_guard block
  confirm_identity "up"
  trap 'echo; warn "interrupted - re-run ./bootstrap.sh up --env '"$ENV_NAME"' (idempotent)"' INT
  SECONDS=0

  step_start "terraform init";  tf_init;  step_done "init"
  step_start "terraform validate"; terraform -chdir="$TF_DIR" validate; step_done "validate"

  local plan="$TF_DIR/$ENV_NAME.tfplan"
  step_start "terraform plan"
  tf plan -input=false -var-file="envs/$ENV_NAME.tfvars" -var "region=$REGION" -out="$plan"
  step_done "plan"

  echo
  read -r -p "Apply this plan in account $ACCOUNT / $REGION? Type 'yes': " ans
  [ "$ans" = yes ] || die "Not applied."
  session_guard block

  step_start "terraform apply (EKS control plane ~9 min, nodes join ~1 min)"
  tf apply -input=false "$plan"
  step_done "apply"

  step_start "aws eks update-kubeconfig"
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
  kube_ctx_ok || die "kubectl context is not $CLUSTER_NAME after update-kubeconfig"
  step_done "kubeconfig"

  step_start "VPC CNI prefix delegation (idempotent; Terraform already did it before the nodes)"
  local pd; pd="$(grep -E '^enable_prefix_delegation' "$TFVARS" | grep -Eo 'true|false' || true)"; pd="${pd:-false}"
  info "enable_prefix_delegation=$pd (from $(basename "$TFVARS"))"
  CLUSTER_NAME="$CLUSTER_NAME" REGION="$REGION" ENABLE_PREFIX_DELEGATION="$pd" "$ROOT/scripts/cni-prefix-delegation.sh"
  step_done "cni prefix"

  step_start "waiting for nodes Ready (timeout 10m)"
  local want; want="$(grep -E '^node_count' "$TFVARS" | grep -Eo '[0-9]+' || true)"; want="${want:-3}"
  local i
  for i in $(seq 1 60); do
    [ "$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')" -ge "$want" ] && break
    sleep 10
  done
  kubectl get nodes
  step_done "nodes"

  argo_install
  argo_wait
  argo_howto

  local total=$((SECONDS/60))
  info "up finished in ${total}m$((SECONDS%60))s"
  [ "$total" -le "$UP_BUDGET_MIN" ] || warn "up took ${total} min, budget is ${UP_BUDGET_MIN}"
  start_reminder
  info "Reminder armed for 1h45m after session start. Push your work before then, then run down."
}

# ---------- down ----------
# Runs on EXIT of `down` (success OR failure). Removes the kubeconfig entries only when
# the cluster is really gone; if it still exists (e.g. PVCs stuck) we keep them so you
# can still kubectl in and debug.
DOWN_VERDICT=""
print_verdict() { # <exit code>
  [ -n "$DOWN_VERDICT" ] || return 0
  if [ "$1" -eq 0 ]; then info "$DOWN_VERDICT"; else warn "$DOWN_VERDICT"; fi
}
cleanup_kubeconfig() {
  local rc=$?
  set +e
  if aws eks describe-cluster --region "$REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1; then
    [ "$rc" -ne 0 ] && warn "cluster $CLUSTER_NAME still exists; keeping kubeconfig entry so you can debug"
    print_verdict "$rc"
    return "$rc"
  fi
  local c
  for c in $(kubectl config get-contexts -o name 2>/dev/null | grep "/$CLUSTER_NAME\$"); do
    kubectl config delete-context "$c" >/dev/null 2>&1
    kubectl config delete-cluster "$c" >/dev/null 2>&1
    kubectl config delete-user "$c" >/dev/null 2>&1
    info "removed kubeconfig entry $c"
  done
  print_verdict "$rc"
  return "$rc"
}

# After a FAILED destroy: forgive ONLY resources listed in envs/<env>.undeletable (things the
# playground lets us create but not delete), and only when (1) the failure was AccessDenied
# and (2) every resource still in state is on that list. Anything else is a real failure.
# This does not touch IAM or retry the denied call; it just stops tracking the leftovers.
destroy_fallback() {
  local log="$1" list="$TF_DIR/envs/$ENV_NAME.undeletable"
  [ -f "$list" ] || return 1
  grep -q "AccessDenied" "$log" || return 1
  local remaining
  remaining="$(tf state list 2>/dev/null | grep -v '^data\.' | sed '/^$/d' || true)"
  [ -n "$remaining" ] || return 1
  local addr why left=""
  while IFS= read -r addr; do
    why="$(awk -F'|' -v a="$addr" '$1==a {print $2; exit}' "$list")"
    if [ -z "$why" ]; then
      warn "destroy failed and '$addr' is NOT on $list: treating as a real failure"
      return 1
    fi
    left+="    - $addr  ($why)"$'\n'
  done <<<"$remaining"
  while IFS= read -r addr; do tf state rm "$addr" >/dev/null; done <<<"$remaining"
  echo
  echo "${c_ylw}WARNING: left behind in AWS (state no longer tracks these):${c_off}"
  printf '%s' "$left"
  echo "  Why: the playground allows creating them but denies deleting them. They are free and"
  echo "  are removed when the playground account is wiped. Until then, a second 'up' in the SAME"
  echo "  account would fail with EntityAlreadyExists for them."
  echo
  return 0
}

# aws_check <thing> <aws args...>: puts the output in CHECK_OUT. A failed call (AccessDenied, network,
# expired credentials) is reported and returns 1: "could not look" must never read as "nothing there".
aws_check() {
  local thing="$1" err rc=0; shift
  err="$(mktemp)"
  CHECK_OUT="$(aws "$@" 2>"$err")" || rc=$?
  CHECK_ERR=""
  if [ "$rc" -ne 0 ]; then
    CHECK_OUT=""
    CHECK_ERR="$(tr '\n' ' ' <"$err" | sed 's/^ *//; s/ *$//')"
    warn "could not check $thing: $CHECK_ERR"
  fi
  rm -f "$err"
  [ "$rc" -eq 0 ]
}

# One leftover_check probe (sets the caller's `bad`).
leftover_probe() { # <thing> <message when something is found> <aws args...>
  local thing="$1" msg="$2"; shift 2
  if ! aws_check "$thing" "$@"; then bad=1
  elif [ -n "$CHECK_OUT" ]; then warn "$msg: $CHECK_OUT"; bad=1
  fi
}

# Independent of Terraform state: anything billable or left behind? Reports only, deletes nothing.
# Fails closed: "clean" is printed only if every check ran AND found nothing. Returns 1 otherwise.
leftover_check() {
  local bad=0 sgs=""
  leftover_probe "EKS clusters" "cluster still listed" \
    eks list-clusters --region "$REGION" --query "clusters[?@=='$CLUSTER_NAME']" --output text
  leftover_probe "EC2 instances" "instances still running" \
    ec2 describe-instances --region "$REGION" --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" "Name=instance-state-name,Values=running,pending" --query 'Reservations[].Instances[].InstanceId' --output text
  leftover_probe "EBS volumes" "unattached EBS volumes (NOT deleted unless tagged kubernetes.io/cluster/$CLUSTER_NAME)" \
    ec2 describe-volumes --region "$REGION" --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text
  leftover_probe "NLB/ALB load balancers" "load balancers" \
    elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].LoadBalancerName' --output text
  leftover_probe "Classic load balancers" "classic load balancers" \
    elb describe-load-balancers --region "$REGION" --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text
  # Security groups the in-tree cloud provider creates for load balancers.
  if aws_check "security groups tagged for $CLUSTER_NAME" ec2 describe-security-groups --region "$REGION" \
       --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER_NAME" --query 'SecurityGroups[].[GroupId,GroupName]' --output text
  then sgs+="$CHECK_OUT"$'\n'; else bad=1; fi
  if aws_check "security groups named k8s-elb-*" ec2 describe-security-groups --region "$REGION" \
       --filters "Name=group-name,Values=k8s-elb-*" --query 'SecurityGroups[].[GroupId,GroupName]' --output text
  then sgs+="$CHECK_OUT"$'\n'; else bad=1; fi
  sgs="$(sed '/^$/d' <<<"$sgs" | sort -u)"
  if [ -n "$sgs" ]; then
    warn "leftover security groups (report only; k8s-elb-* may belong to ANOTHER cluster - check tags before deleting):"
    echo "$sgs" >&2; bad=1
  fi
  if [ "$bad" = 0 ]; then
    info "leftover check clean (no cluster, instances, unattached volumes, load balancers, security groups)"
  else
    warn "leftover check NOT clean (see warnings above)"
  fi
  return "$bad"
}

# Wait until no load balancer (NLB/ALB or Classic) is left in the VPC. A failed call means "unknown",
# which counts as "still there": terraform destroy must not start on a guess. Gives up with the AWS
# error after LB_MAX_FAILS consecutive failed polls, or after LB_WAIT_TRIES polls in total.
wait_lbs_gone() { # <vpc-id>
  local vpc="$1" tries="${LB_WAIT_TRIES:-30}" max_fails="${LB_MAX_FAILS:-6}" i fails=0 left err
  for i in $(seq 1 "$tries"); do
    left=""; err=""
    if aws_check "NLB/ALB load balancers" elbv2 describe-load-balancers --region "$REGION" \
         --query "LoadBalancers[?VpcId=='$vpc'].LoadBalancerArn" --output text
    then left+="$CHECK_OUT"; else err="$CHECK_ERR"; fi
    if aws_check "Classic load balancers" elb describe-load-balancers --region "$REGION" \
         --query "LoadBalancerDescriptions[?VPCId=='$vpc'].LoadBalancerName" --output text
    then left+=" $CHECK_OUT"; else err="$CHECK_ERR"; fi
    left="$(xargs <<<"$left")"
    if [ -n "$err" ]; then
      fails=$((fails+1))
      [ "$fails" -lt "$max_fails" ] || die "cannot verify that the load balancers in $vpc are gone ($fails failed checks in a row): $err"
    else
      fails=0
      [ -n "$left" ] || return 0
    fi
    [ "$i" -lt "$tries" ] && sleep 10
  done
  [ -z "$err" ] || die "cannot verify that the load balancers in $vpc are gone: $err"
  die "Load balancers still exist in $vpc after $tries checks: $left"
}

# GONE | ACTIVE/CREATING/DELETING/... | ERROR:<message>. Only ResourceNotFoundException counts as gone;
# credential/network errors must not be mistaken for "no cluster".
cluster_state() {
  local out
  if out="$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER_NAME" --query cluster.status --output text 2>&1)"; then
    echo "$out"
  elif grep -q ResourceNotFoundException <<<"$out"; then
    echo GONE
  else
    echo "ERROR:$out"
  fi
}

# Orphans the EBS CSI driver leaves when the cluster dies before it could clean up. Deletes ONLY
# unattached ("available") volumes tagged kubernetes.io/cluster/<this cluster>, which the driver sets
# via controller.k8sTagClusterId (platform/values/aws-ebs-csi-driver.yaml). The driver's generic
# ebs.csi.aws.com/cluster=true tag is set by EVERY cluster in the account, so another cluster's
# volumes could match: it is NOT a delete criterion. Volumes with only the generic tag, or none,
# are reported by leftover_check as warnings and left alone.
delete_orphan_volumes() {
  local ids id name
  aws_check "orphaned volumes (nothing deleted)" ec2 describe-volumes --region "$REGION" \
    --filters Name=status,Values=available "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER_NAME" \
    --query 'Volumes[].VolumeId' --output text || return 0
  ids="$(tr '\t' '\n' <<<"$CHECK_OUT" | sed '/^$/d' | sort -u)"
  [ -n "$ids" ] || return 0
  for id in $ids; do
    name="$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$id" --query "Volumes[0].Tags[?Key=='kubernetes.io/created-for/pvc/name'].Value | [0]" --output text 2>/dev/null || true)"
    info "deleting orphaned volume $id (pvc: ${name:-?}) - unattached, tagged kubernetes.io/cluster/$CLUSTER_NAME"
    aws ec2 delete-volume --region "$REGION" --volume-id "$id" >/dev/null || warn "could not delete $id"
  done
}

cmd_down() {
  parse_env "$@"; resolve_region
  confirm_identity "down"
  trap cleanup_kubeconfig EXIT
  SECONDS=0
  session_guard

  local cs gone=0; cs="$(cluster_state)"
  case "$cs" in
    ERROR:*) die "cannot tell whether cluster $CLUSTER_NAME exists: ${cs#ERROR:}" ;;
    DELETING) # someone else (e.g. the playground) is deleting it: kubectl is useless, wait for it
      step_start "cluster is DELETING (not started by us) - waiting up to 15 min"
      for _ in $(seq 1 90); do cs="$(cluster_state)"; [ "$cs" = DELETING ] || break; sleep 10; done
      [ "$cs" = GONE ] || die "cluster still $cs after waiting"
      step_done "cluster gone" ;;
  esac
  [ "$cs" = GONE ] && gone=1

  if [ "$gone" = 0 ]; then
    step_start "point kubectl at $CLUSTER_NAME"
    aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" >/dev/null
    kube_ctx_ok || die "kubectl context is not $CLUSTER_NAME"
    step_done "kubeconfig"

    # Why first: Services of type LoadBalancer create ELBs and PVCs create EBS volumes
    # OUTSIDE Terraform (the controllers inside the cluster make them). terraform destroy
    # does not know them, so it would delete the cluster and leave them running
    # (costing money) - and the ELB's ENIs/security groups would block deleting the VPC
    # objects Terraform does own. Deleting them while the controllers still run lets
    # the cluster clean up after itself.
    # Argo's selfHeal would recreate anything we delete below, so stop its controller first.
    step_start "stop Argo CD controller (so selfHeal does not recreate what we delete)"
    kubectl -n argocd scale statefulset argocd-application-controller --replicas=0 2>/dev/null \
      && kubectl -n argocd wait --for=delete pod -l app.kubernetes.io/name=argocd-application-controller --timeout=120s 2>/dev/null || true
    step_done "argo stopped"

    # Envoy Gateway would recreate its proxy Services if we deleted only them, so remove the Gateways
    # first (Argo is stopped, so they stay gone) and let the controller delete its load balancers.
    step_start "delete Gateways (their controller then removes the load balancer Services)"
    if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
      kubectl delete gateway --all -A --wait=true --timeout=180s || warn "some Gateways did not delete"
      local g
      for g in $(seq 1 36); do
        [ -z "$(kubectl get svc -A -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer") | .metadata.name')" ] && break
        sleep 5
      done
    fi
    step_done "gateways"

    step_start "delete LoadBalancer Services"
    kubectl get svc -A -o json \
      | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' \
      | while read -r ns name; do kubectl delete svc -n "$ns" "$name" --wait=true --timeout=300s; done
    step_done "services"

    # A PVC held by a running pod never finishes deleting (pvc-protection finalizer), so
    # scale every StatefulSet/Deployment in namespaces that own PVCs to 0 first. Argo is already
    # stopped, so nothing scales them back. kube-system/argocd are skipped: the EBS CSI
    # controller must keep running to detach and delete the volumes.
    step_start "scale workloads in PVC namespaces to 0 (release volumes)"
    kubectl get pvc -A -o json | jq -r '.items[].metadata.namespace' | sort -u \
      | grep -vxE 'kube-system|argocd' | while read -r ns; do
          kubectl -n "$ns" scale statefulset,deployment --all --replicas=0 >/dev/null
          kubectl -n "$ns" wait --for=delete pod --all --timeout=180s >/dev/null 2>&1 \
            || warn "pods still terminating in $ns"
        done
    step_done "workloads scaled down"

    step_start "delete PVCs (releases EBS volumes)"
    kubectl delete pvc --all -A --wait=true --timeout=180s \
      || die "PVCs still bound (a pod likely uses them). Delete the owning workloads, then re-run down."
    if [ "$(kubectl get pv --no-headers 2>/dev/null | wc -l)" -gt 0 ]; then
      kubectl wait --for=delete pv --all --timeout=180s \
        || die "PersistentVolumes still present: $(kubectl get pv --no-headers | awk '{print $1}' | tr '\n' ' ')"
    fi
    step_done "pvcs"

    step_start "wait for load balancers in the VPC to disappear"
    local vpc; vpc="$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
    wait_lbs_gone "$vpc"
    step_done "elb wait"
  else
    info "No cluster $CLUSTER_NAME in $REGION - skipping Kubernetes cleanup"
  fi

  step_start "terraform init";  tf_init;  step_done "init"
  if [ "$gone" = 1 ]; then
    # Resources that live INSIDE the cluster (kubernetes_* provider) cannot be refreshed or destroyed
    # without it: the provider falls back to localhost:80 and destroy fails. They died with the cluster.
    local k; k="$(tf state list 2>/dev/null | grep '^kubernetes_' || true)"
    if [ -n "$k" ]; then
      step_start "cluster is gone: dropping in-cluster resources from Terraform state"
      while IFS= read -r a; do tf state rm "$a" >/dev/null && info "state rm $a"; done <<<"$k"
      step_done "state rm"
    fi
  fi
  step_start "terraform destroy"
  local log; log="$(mktemp)"
  # stderr is copied to $log (terraform prints errors there); the confirm prompt stays on the tty
  if ! tf destroy -input=false -var-file="envs/$ENV_NAME.tfvars" -var "region=$REGION" 2> >(tee "$log" >&2); then
    sleep 1   # let tee flush
    destroy_fallback "$log" || { rm -f "$log"; die "terraform destroy failed (see above)"; }
  fi
  rm -f "$log"
  step_done "destroy"

  step_start "orphaned volumes tagged kubernetes.io/cluster/$CLUSTER_NAME (unattached)"
  delete_orphan_volumes
  step_done "orphan volumes"

  step_start "leftover check (independent of terraform state)"
  local dirty=0
  leftover_check || dirty=1
  step_done "leftover check"

  rm -rf "$RUN_DIR"
  # The verdict is printed by the EXIT trap (cleanup_kubeconfig) so it is the LAST line of the output.
  local took="$((SECONDS/60))m$((SECONDS%60))s"
  if [ "$dirty" = 0 ]; then
    DOWN_VERDICT="down complete in $took: leftover check clean"
  else
    DOWN_VERDICT="down finished in $took BUT the leftover check is NOT clean - read the warnings above (exit 3)"
    exit 3
  fi
}

# ---------- status ----------
cmd_status() {
  if [ $# -gt 0 ]; then parse_env "$@"; fi
  resolve_region
  local ident; ident="$(aws sts get-caller-identity --output json)" || die "no AWS credentials"
  echo "Account: $(jq -r .Account <<<"$ident")  Region: $REGION"
  echo "Session: $(session_elapsed_min) min elapsed of $SESSION_LIMIT_MIN (warn at $WARN_AT_MIN)"
  session_guard
  local st; st="$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER_NAME" --query 'cluster.[status,version]' --output text 2>/dev/null || true)"
  if [ -z "$st" ]; then echo "Cluster $CLUSTER_NAME: not found"; return 0; fi
  echo "Cluster $CLUSTER_NAME: $st"
  if kube_ctx_ok; then
    kubectl get nodes
    echo
    if kubectl get applications -n argocd >/dev/null 2>&1; then
      echo "Argo apps (name sync health):"
      argo_app_rows | column -t
      local bad; bad="$(argo_app_rows | awk '$2!="Synced" || $3!="Healthy"' | wc -l)"
      [ "$bad" = 0 ] && echo "Argo: all apps Synced+Healthy" || warn "$bad app(s) not Synced+Healthy"
    else
      echo "Argo: not installed (or no applications yet)"
    fi
  else warn "kubectl context is not $CLUSTER_NAME"; fi
}

usage() { sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  check)  shift; cmd_check "$@" ;;
  up)     shift; cmd_up "$@" ;;
  down)   shift; cmd_down "$@" ;;
  status) shift; cmd_status "$@" ;;
  -h|--help|help|"") usage ;;
  *) usage; exit 2 ;;
esac
