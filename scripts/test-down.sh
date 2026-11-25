#!/usr/bin/env bash
# Stub test for `down`: the load balancer wait and the exit codes. No AWS or cluster access:
# aws, kubectl, terraform and sleep are replaced. Usage: scripts/test-down.sh
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
rc=0
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; echo "$2"; rc=1; }

# Runs wait_lbs_gone in a fresh shell. PLAN_<api> = space-separated answer per poll: gone | here | fail
# (the last one repeats).
lbwait() { # <elbv2 plan> <elb plan>
  rm -f "$work"/n.*
  P_V2="$1" P_V1="$2" W="$work" bash -c '
    source "'"$ROOT_DIR"'/bootstrap.sh" >/dev/null 2>&1 || true
    REGION=us-east-1; sleep() { :; }
    aws() {
      local api="$1" plan n word
      [ "$api" = elbv2 ] && plan="$P_V2" || plan="$P_V1"
      n=$(( $(cat "$W/n.$api" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$W/n.$api"
      word=$(awk -v n="$n" "{ print (n<=NF) ? \$n : \$NF }" <<<"$plan")
      case "$word" in
        gone) ;;
        here) echo "lb-$api" ;;
        fail) echo "An error occurred (AccessDenied) when calling $api" >&2; return 254 ;;
      esac
    }
    LB_WAIT_TRIES=8 LB_MAX_FAILS=3 wait_lbs_gone vpc-1 && echo RESULT-GONE' 2>&1 | strip
}
polls() { cat "$work/n.elbv2"; }

o="$(lbwait gone gone)";               grep -q RESULT-GONE <<<"$o" && [ "$(polls)" = 1 ] && ok "both empty -> gone at once" || bad "gone" "$o"
o="$(lbwait "here here gone" gone)";   grep -q RESULT-GONE <<<"$o" && [ "$(polls)" = 3 ] && ok "waits while one exists" || bad "wait" "$o"
o="$(lbwait fail gone)"
grep -q RESULT-GONE <<<"$o" && bad "elbv2 failure read as gone" "$o" || { grep -q "STOP: cannot verify.*AccessDenied" <<<"$o" && [ "$(polls)" = 3 ] \
  && ok "elbv2 keeps failing, elb empty -> NOT gone, stops with the AWS error" || bad "elbv2 fail" "$o"; }
o="$(lbwait gone fail)";               grep -q "STOP: cannot verify.*AccessDenied" <<<"$o" && ! grep -q RESULT-GONE <<<"$o" && ok "elb keeps failing -> stops with the AWS error" || bad "elb fail" "$o"
o="$(lbwait "fail fail gone" gone)";   grep -q RESULT-GONE <<<"$o" && [ "$(polls)" = 3 ] && ok "transient failure then empty -> gone" || bad "transient" "$o"
o="$(lbwait here gone)";               grep -q "STOP: Load balancers still exist.*lb-elbv2" <<<"$o" && ok "never disappears -> stops and names it" || bad "timeout" "$o"

# Whole `down` with the cluster already gone: exit code and last line.
down_run() { # LEFT=1 -> something is left behind
  LEFT="$1" W="$work" bash -c '
    source "'"$ROOT_DIR"'/bootstrap.sh" >/dev/null 2>&1 || true
    ENV_NAME=kodekloud; REGION=us-east-1; CLUSTER_NAME=demo-eks; RUN_DIR="$W/run"
    parse_env() { :; }; resolve_region() { :; }; confirm_identity() { :; }; session_guard() { :; }
    tf_init() { :; }; tf() { :; }; kubectl() { :; }
    aws() {
      case "$*" in
        "eks describe-cluster"*) echo "ResourceNotFoundException" >&2; return 254 ;;
        "elb describe-load-balancers"*) [ "$LEFT" = 1 ] && echo classic-lb-1; return 0 ;;
      esac
    }
    cmd_down --env kodekloud' > "$work/down.log" 2>&1
  code=$?
  last="$(strip < "$work/down.log" | tail -n1)"
}
down_run 0
[ "$code" = 0 ] && grep -q "down complete.*leftover check clean" <<<"$last" && ok "clean down -> exit 0, verdict is the last line" || bad "clean down (exit $code)" "$(strip < "$work/down.log")"
down_run 1
[ "$code" = 3 ] && grep -q "NOT clean.*(exit 3)" <<<"$last" && ok "leftovers -> exit 3, verdict is the last line" || bad "dirty down (exit $code)" "$(strip < "$work/down.log")"
exit $rc
