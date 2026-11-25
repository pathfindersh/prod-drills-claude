#!/usr/bin/env bash
# The repo is public. Fails if a file git would publish contains (1) this machine's public IP or the
# ADMIN_CIDR address, or (2) any IPv4 /32 outside the documentation ranges of RFC 5737
# (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24). Prints file:line only, never the address.
# Fail closed: if the public IP cannot be detected, the check fails. Does not read git history.
# Usage: scripts/check-no-ip.sh [repo-dir]
set -euo pipefail
cd "${1:-$(dirname "$0")/..}"
ip_re='((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])'
mine="$(curl -fsS --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
grep -Eqx "$ip_re" <<<"$mine" || { echo "FAIL: could not detect the public IP, so the IP check did not run"; exit 1; }
files() { git ls-files -z --cached --others --exclude-standard; }
# search <regex>: matching "file:line:text"; exit status of grep errors is not hidden (>1 = failed)
search() {
  local rc=0
  files | xargs -0 -r sh -c 'for f; do [ -f "$f" ] && printf "%s\0" "$f"; done' sh | xargs -0 -r grep -HnIoE -e "$1" -- || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 123 ] || { echo "FAIL: search failed (status $rc)" >&2; return 2; }
}
admin="${ADMIN_CIDR:-}"
bad=0
for a in "$mine" "${admin%/*}"; do
  grep -Eqx "$ip_re" <<<"${a:-}" || continue
  hits="$(search "(^|[^0-9.])${a//./\\.}([^0-9]|\$)")"
  if [ -n "$hits" ]; then echo "FAIL: your public/admin IP is in:"; cut -d: -f1,2 <<<"$hits" | sort -u; bad=1; fi
done
# one output line per address (no boundary characters: they would swallow the next address)
hits="$(search "$ip_re/32")"
hits="$(grep -vE ':(192\.0\.2|198\.51\.100|203\.0\.113)\.[0-9]+/32$' <<<"$hits" || true)"
if [ -n "$hits" ]; then echo "FAIL: /32 address that is not a documentation example in:"; cut -d: -f1,2 <<<"$hits" | sort -u; bad=1; fi
[ "$bad" = 0 ] && echo "ok   no public/admin IP and no non-example /32 in tracked files"
exit "$bad"
