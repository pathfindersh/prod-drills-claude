#!/usr/bin/env bash
# Turn on VPC CNI prefix delegation (each ENI slot hands out a /28 prefix = 16 IPs, so
# t3.medium can run ~110 pods instead of 17). MUST run before nodes advertise maxPods=110
# (nodes.tf), otherwise the scheduler would place pods the CNI cannot give IPs to.
# Idempotent. Called by Terraform (terraform_data.cni_prefix, before the node ASG exists)
# and by `bootstrap.sh up` as a drift safety net. Uses its own temp kubeconfig, so it never
# touches the user's current kubectl context.
set -euo pipefail
: "${CLUSTER_NAME:?}" "${REGION:?}"
KUBECONFIG="$(mktemp)"; export KUBECONFIG
trap 'rm -f "$KUBECONFIG"' EXIT
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG" >/dev/null
for i in $(seq 1 60); do   # the aws-node DaemonSet appears a little after the cluster turns ACTIVE
  kubectl -n kube-system get ds aws-node >/dev/null 2>&1 && break
  sleep 5
done
kubectl -n kube-system get ds aws-node >/dev/null
kubectl -n kube-system set env ds/aws-node ENABLE_PREFIX_DELEGATION=true WARM_PREFIX_TARGET=1
kubectl -n kube-system rollout status ds/aws-node --timeout=300s
