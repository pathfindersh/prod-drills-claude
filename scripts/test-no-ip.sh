#!/usr/bin/env bash
# Stub test for check-no-ip.sh (throwaway git repo, curl replaced). No network.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/repo"; git -C "$work/repo" init -q
printf '#!/bin/sh\n[ -n "$FAKE_IP" ] || exit 6\necho "$FAKE_IP"\n' > "$work/bin/curl"; chmod +x "$work/bin/curl"
me=198.18.0.7; other=198.18.0.9   # benchmarking range: not real hosts, not documentation examples
rc=0
t() { # name expected-status file-content fake-ip [admin-cidr]
  printf '%s\n' "$3" > "$work/repo/f.md"; local got=0
  PATH="$work/bin:$PATH" FAKE_IP="$4" ADMIN_CIDR="${5:-}" "$here/check-no-ip.sh" "$work/repo" >"$work/out" 2>&1 || got=$?
  if [ "$got" != "$2" ]; then echo "FAIL $1: status $got, want $2"; cat "$work/out"; rc=1
  elif grep -qF -e "$me" -e "$other" "$work/out"; then echo "FAIL $1: address printed"; rc=1
  else echo "ok   $1"; fi
}
t "clean file"                  0 "nothing here" "$me"
t "own IP, bare"                1 "from ($me)." "$me"
t "longer address is not ours"  0 "x ${me}1 y" "$me"
t "non-example /32"             1 "cidr: $other/32" "$me"
t "documentation /32"           0 "cidr: 203.0.113.7/32" "$me"
t "example does not hide other" 1 "203.0.113.7/32 $other/32" "$me"
t "ADMIN_CIDR address"          1 "host $other" "$me" "$other/32"
t "IP detection fails"          1 "nothing here" ""
exit $rc
