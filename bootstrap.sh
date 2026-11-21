#!/usr/bin/env bash
# bootstrap.sh - bring the lab up/down from any machine.
#   ./bootstrap.sh check
#   ./bootstrap.sh up   --env <kodekloud|personal>
#   ./bootstrap.sh down --env <kodekloud|personal>
#   ./bootstrap.sh status [--env <env>]
# All subcommands are idempotent. `up` = terraform + Argo CD (helm) + root App of Apps;
# Argo then syncs everything under platform/ from Git. Set GITOPS_REVISION=<branch> to make
# Argo follow a branch other than main (testing before merge).
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
ARGOCD_REPO="https://argoproj.github.io/argo-helm"
argocd_chart_version() { # single source of truth: platform/apps/values.yaml
  sed -n 's/^ *argocd: .*version: *\([0-9][0-9.]*\).*/\1/p' "$ROOT/platform/apps/values.yaml"
}

# JSON of all Applications -> "name sync health" lines
argo_app_rows() {
  kubectl get applications -n argocd -o json 2>/dev/null \
    | jq -r '.items[] | "\(.metadata.name) \(.status.sync.status // "?") \(.status.health.status // "?")"'
}

argo_install() {
  local ver; ver="$(argocd_chart_version)"; [ -n "$ver" ] || die "cannot read argocd chart version from platform/apps/values.yaml"
  step_start "helm install Argo CD chart $ver (same values file Argo later uses to manage itself)"
  helm upgrade --install argocd argo-cd --repo "$ARGOCD_REPO" --version "$ver" \
    --namespace argocd --create-namespace -f "$ROOT/platform/values/argocd.yaml" --wait --timeout 8m
  step_done "argocd helm"

  step_start "apply bootstrap/root.yaml (App of Apps)"
  local rev="${GITOPS_REVISION:-}"
  if [ -n "$rev" ]; then
    warn "Argo will follow branch '$rev' instead of main (GITOPS_REVISION)"
    sed "/GITOPS_REV/ s|: main #|: $rev #|" "$ROOT/bootstrap/root.yaml" | kubectl apply -f -
  else
    kubectl apply -f "$ROOT/bootstrap/root.yaml"
  fi
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
  local pw; pw="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
  echo
  info "Argo CD UI:  kubectl port-forward svc/argocd-server -n argocd 8080:80   ->  http://localhost:8080"
  if [ -n "$pw" ]; then
    echo "    user: admin   password (generated by Argo, shown once, never stored in Git): $pw"
  else
    echo "    admin password secret not found (already deleted?)"
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
cleanup_kubeconfig() {
  local rc=$?
  set +e
  if aws eks describe-cluster --region "$REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1; then
    [ "$rc" -ne 0 ] && warn "cluster $CLUSTER_NAME still exists; keeping kubeconfig entry so you can debug"
    return "$rc"
  fi
  local c
  for c in $(kubectl config get-contexts -o name 2>/dev/null | grep "/$CLUSTER_NAME\$"); do
    kubectl config delete-context "$c" >/dev/null 2>&1
    kubectl config delete-cluster "$c" >/dev/null 2>&1
    kubectl config delete-user "$c" >/dev/null 2>&1
    info "removed kubeconfig entry $c"
  done
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

# Independent of Terraform state: anything billable still there?
leftover_check() {
  local bad=0 out
  out="$(aws eks list-clusters --region "$REGION" --query "clusters[?@=='$CLUSTER_NAME']" --output text 2>/dev/null || true)"
  [ -z "$out" ] || { warn "cluster still listed: $out"; bad=1; }
  out="$(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" "Name=instance-state-name,Values=running,pending" --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
  [ -z "$out" ] || { warn "instances still running: $out"; bad=1; }
  out="$(aws ec2 describe-volumes --region "$REGION" --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)"
  [ -z "$out" ] || { warn "unattached EBS volumes: $out"; bad=1; }
  out="$(aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null || true)"
  [ -z "$out" ] || { warn "load balancers: $out"; bad=1; }
  [ "$bad" = 0 ] && info "leftover check clean (no cluster, instances, unattached volumes, load balancers)"
  return 0
}

cmd_down() {
  parse_env "$@"; resolve_region
  confirm_identity "down"
  trap cleanup_kubeconfig EXIT
  SECONDS=0
  session_guard

  if aws eks describe-cluster --region "$REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1; then
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

    step_start "delete LoadBalancer Services"
    kubectl get svc -A -o json \
      | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' \
      | while read -r ns name; do kubectl delete svc -n "$ns" "$name" --wait=true --timeout=300s; done
    step_done "services"

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
    local i left
    for i in $(seq 1 30); do
      left="$( { aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[?VpcId=='$vpc'].LoadBalancerArn" --output text
                 aws elb describe-load-balancers --region "$REGION" --query "LoadBalancerDescriptions[?VPCId=='$vpc'].LoadBalancerName" --output text; } | tr -d '[:space:]')"
      [ -z "$left" ] && break
      sleep 10
    done
    [ -z "$left" ] || die "Load balancers still exist in $vpc after 5 min: $left"
    step_done "elb wait"
  else
    info "No cluster $CLUSTER_NAME in $REGION - skipping Kubernetes cleanup"
  fi

  step_start "terraform init";  tf_init;  step_done "init"
  step_start "terraform destroy"
  local log; log="$(mktemp)"
  # stderr is copied to $log (terraform prints errors there); the confirm prompt stays on the tty
  if ! tf destroy -input=false -var-file="envs/$ENV_NAME.tfvars" -var "region=$REGION" 2> >(tee "$log" >&2); then
    sleep 1   # let tee flush
    destroy_fallback "$log" || { rm -f "$log"; die "terraform destroy failed (see above)"; }
  fi
  rm -f "$log"
  step_done "destroy"

  step_start "leftover check (independent of terraform state)"
  leftover_check
  step_done "leftover check"

  rm -rf "$RUN_DIR"
  info "down complete in $((SECONDS/60))m$((SECONDS%60))s"   # kubeconfig is cleaned by the EXIT trap
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
