#!/usr/bin/env bash
# Ephemeral test environment (the steady state keeps shop-test empty; /test answers 503).
#   scripts/test-env.sh up           browse + cart (6 pods)
#   scripts/test-env.sh up --order   order-capable core (8 pods): short runs only, no deploys meanwhile
#   scripts/test-env.sh down         remove the apps and the redis volume
#   scripts/test-env.sh status
# Creates a second ApplicationSet from the same template as the permanent one. It is not part of the
# root app, so Argo neither prunes it nor recreates it after `down`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-demo-eks}"
APPSET=online-boutique-test
die() { echo "STOP: $*" >&2; exit 1; }

check_context() {
  local c; c="$(kubectl config current-context)"
  case "$c" in */"$CLUSTER_NAME") ;; *) die "kubectl context '$c' is not cluster $CLUSTER_NAME" ;; esac
}

free_slots() { # allocatable pods on all nodes minus pods that occupy a slot
  local alloc used
  alloc="$(kubectl get nodes -o json | jq '[.items[].status.allocatable.pods | tonumber] | add')"
  used="$(kubectl get pods -A -o json | jq '[.items[] | select(.status.phase!="Succeeded" and .status.phase!="Failed")] | length')"
  echo $((alloc - used))
}

render() { # revision set(browse|order)
  local services
  services="$(python3 -I -c 'import sys,yaml,json; print(json.dumps(yaml.safe_load(open(sys.argv[1]))["onlineBoutique"]["testRun"][sys.argv[2]]))' "$ROOT/platform/apps/values.yaml" "$2")"
  helm template root "$ROOT/platform/apps" --show-only templates/online-boutique.yaml \
    --set "revision=$1" --set "onlineBoutique.name=$APPSET" \
    --set-json "onlineBoutique.environments={\"dev\":[],\"prod\":[],\"test\":$services}"
}

cmd_up() {
  local set=browse need=6
  case "${1:-}" in "") ;; --order) set=order; need=8 ;; *) die "unknown option $1" ;; esac
  check_context
  if kubectl -n argocd get applicationset online-boutique -o json | jq -e '.spec.generators[0].list.elements[] | select(.env=="test")' >/dev/null; then
    die "test is already part of the permanent ApplicationSet in this environment"
  fi
  if ! kubectl -n argocd get applicationset "$APPSET" >/dev/null 2>&1; then
    local free; free="$(free_slots)"
    [ "$free" -ge "$need" ] || die "need $need free pod slots, only $free"
    echo "free pod slots: $free, test needs $need"
  fi
  local rev; rev="$(kubectl -n argocd get application root -o jsonpath='{.spec.source.targetRevision}')"
  [ -n "$rev" ] || die "cannot read the root app revision"
  render "$rev" "$set" | kubectl apply -f -
  echo "test ($set) requested from revision $rev. Watch: kubectl get pods -n shop-test"
  echo "NOTE: test uses the spare pod slots - do not deploy or drain while it runs; run '$0 down' afterwards."
}

cmd_down() {
  check_context
  kubectl -n argocd delete applicationset "$APPSET" --ignore-not-found
  kubectl -n argocd wait --for=delete application -l environment=test --timeout=300s
  # StatefulSets keep their PVC; delete it so no EBS volume is left behind.
  kubectl -n shop-test delete pvc --all --timeout=180s
  echo "test removed; /test answers 503 again"
}

case "${1:-}" in
  up)     shift; cmd_up "$@" ;;
  down)   cmd_down ;;
  status) check_context; kubectl -n argocd get applications -l environment=test; kubectl -n shop-test get pods,pvc ;;
  render) render "${2:-main}" "${3:-browse}" ;;   # offline: print the ApplicationSet
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
