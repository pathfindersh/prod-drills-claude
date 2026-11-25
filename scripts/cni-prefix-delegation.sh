#!/usr/bin/env bash
# Set VPC CNI prefix delegation to the requested state (each ENI slot hands out a /28 = 16 IPs,
# so t3.medium runs ~110 pods instead of 17). MUST be applied BEFORE nodes advertise maxPods=110
# (nodes.tf), otherwise the scheduler would place pods the CNI cannot give IPs to.
# ENABLE_PREFIX_DELEGATION=true|false is required; setting the value it already has is a no-op
# (no DaemonSet rollout), so running this with false on a default cluster changes nothing.
# Idempotent. Called by Terraform (terraform_data.cni_prefix, before the node ASG exists) and by
# `bootstrap.sh up` as a drift safety net. Uses its own temp kubeconfig, never your current context.
set -euo pipefail
: "${CLUSTER_NAME:?}" "${REGION:?}" "${ENABLE_PREFIX_DELEGATION:?must be true or false}"
case "$ENABLE_PREFIX_DELEGATION" in true|false) ;; *) echo "ENABLE_PREFIX_DELEGATION must be true or false" >&2; exit 2 ;; esac
KUBECONFIG="$(mktemp)"; export KUBECONFIG
trap 'rm -f "$KUBECONFIG"' EXIT
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG" >/dev/null
for i in $(seq 1 60); do   # the aws-node DaemonSet appears a little after the cluster turns ACTIVE
  kubectl -n kube-system get ds aws-node >/dev/null 2>&1 && break
  sleep 5
done
kubectl -n kube-system get ds aws-node >/dev/null
if [ "$ENABLE_PREFIX_DELEGATION" = true ]; then
  kubectl -n kube-system set env ds/aws-node ENABLE_PREFIX_DELEGATION=true WARM_PREFIX_TARGET=1
else
  kubectl -n kube-system set env ds/aws-node ENABLE_PREFIX_DELEGATION=false
fi
kubectl -n kube-system rollout status ds/aws-node --timeout=300s
