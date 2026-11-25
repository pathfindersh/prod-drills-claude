#!/usr/bin/env bash
# helm lint + helm template | kubeconform for every service x env values combo.
# Usage: scripts/validate-charts.sh [env ...]   (default: dev)
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/check-no-ip.sh
KC="${KUBECONFORM:-kubeconform}"
K8S="${K8S_VERSION:-1.34.0}"
CACHE="${KUBECONFORM_CACHE:-${TMPDIR:-/tmp}/kubeconform-cache}"; mkdir -p "$CACHE"
# kubeconform downloads schemas on first use; the download occasionally stalls -> timeout + retry.
kc() { local i; for i in 1 2 3; do timeout 30 "$KC" -cache "$CACHE" -strict -summary -kubernetes-version "$K8S" "$@" && return 0; [ $? -eq 124 ] || return 1; done; return 1; }
envs=("${@:-dev}")
rc=0
for s in apps/online-boutique/*/; do
  n=$(basename "$s")
  for e in "${envs[@]}"; do
    args=(-f "$s/values.yaml" -f "$s/values-$e.yaml")
    helm lint charts/microservice "${args[@]}" >/dev/null || { echo "LINT FAIL $n/$e"; rc=1; }
    helm template "$n" charts/microservice -n "shop-$e" "${args[@]}" > "$CACHE/$n.yaml"
    out=$(kc "$CACHE/$n.yaml" 2>&1) || { echo "KUBECONFORM FAIL $n/$e: $out"; rc=1; continue; }
    echo "$n/$e: $out"
  done
done
exit $rc
