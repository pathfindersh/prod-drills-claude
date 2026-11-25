#!/usr/bin/env bash
# Stub test for bootstrap.sh leftover_check / delete_orphan_volumes. No AWS access: `aws` is replaced.
# Usage: scripts/test-leftover-check.sh
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/bootstrap.sh" >/dev/null 2>&1 || true
set +e
REGION=us-east-1; CLUSTER_NAME=demo-eks
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT
FAIL_ON=""; FOUND=0; rc=0

aws() {
  local key
  case "$*" in
    "eks list-clusters"*) key=clusters ;;
    "ec2 describe-instances"*) key=instances ;;
    "ec2 describe-volumes"*) key=volumes ;;
    "elbv2 describe-load-balancers"*) key=elbv2 ;;
    "elb describe-load-balancers"*) key=elb ;;
    "ec2 describe-security-groups"*tag-key*) key=sg-tag ;;
    "ec2 describe-security-groups"*group-name*) key=sg-name ;;
    "ec2 delete-"*) echo "DELETE $*" >> "$LOG"; return 0 ;;
    *) echo "unexpected call: $*" >&2; return 99 ;;
  esac
  if [ "$FAIL_ON" = "$key" ] || [ "$FAIL_ON" = all ]; then
    echo "An error occurred (AccessDenied) when calling $key" >&2; return 254
  fi
  if [ "$FOUND" = 1 ]; then
    case "$key" in
      sg-tag|sg-name) printf 'sg-aaa\tk8s-elb-aaa\n' ;;
      elb) echo classic-lb-1 ;;
    esac
  fi
}

run() { "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
expect() { # <name> <output> <must contain> [must NOT contain]
  if ! grep -qF -- "$3" <<<"$2"; then echo "FAIL $1: missing '$3'"; echo "$2"; rc=1
  elif [ -n "${4:-}" ] && grep -qF -- "$4" <<<"$2"; then echo "FAIL $1: must not contain '$4'"; echo "$2"; rc=1
  else echo "ok   $1"; fi
}

out="$(run leftover_check)"
expect "all checks run, nothing found -> clean" "$out" "leftover check clean" "WARN"

for k in clusters instances volumes elbv2 elb sg-tag sg-name all; do
  FAIL_ON=$k; out="$(run leftover_check)"
  expect "failed call ($k) -> warned" "$out" "WARN: could not check " "leftover check clean"
  expect "failed call ($k) -> error text shown, not clean" "$out" "AccessDenied" "leftover check clean"
done
FAIL_ON=""

FOUND=1; out="$(run leftover_check)"
expect "security group reported, not clean" "$out" "sg-aaa" "leftover check clean"
expect "classic ELB reported" "$out" "classic load balancers: classic-lb-1"
[ "$(grep -c '^sg-aaa' <<<"$out")" = 1 ] && echo "ok   same group from both queries listed once" || { echo "FAIL duplicate groups"; rc=1; }
FOUND=0

FAIL_ON=volumes; out="$(run delete_orphan_volumes)"
expect "volume cleanup: failed describe is reported" "$out" "could not check orphaned volumes"
[ ! -s "$LOG" ] && echo "ok   nothing was ever deleted" || { echo "FAIL delete calls:"; cat "$LOG"; rc=1; }
exit $rc
