#!/usr/bin/env bash
# Pins the EXACT bytes of the node user_data (MIME multipart for nodeadm). If it is not valid MIME
# starting at column 0, nodes boot but never join. Renders infra/terraform/templates/user_data.tpl
# with placeholder values for both enable_prefix_delegation values and compares with the golden files
# (generated from the known-good versions in git history: on = b00f01a, off = 29ef43d).
# Needs only terraform (no AWS). Usage: scripts/test-user-data.sh
set -euo pipefail
cd "$(dirname "$0")/../infra/terraform"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cp templates/user_data.tpl "$work/user_data.tpl"
cat > "$work/main.tf" <<'TF'
variable "prefix" { type = bool }
output "ud" {
  value = templatefile("${path.module}/user_data.tpl", {
    cluster_name      = "demo-eks"
    endpoint          = "https://EXAMPLE.eks.amazonaws.com"
    ca_data           = "Q0FEQVRB"
    service_cidr      = "10.100.0.0/16"
    prefix_delegation = var.prefix
  })
}
TF
rc=0
for v in true false; do
  [ "$v" = true ] && g=testdata/user_data.prefix_on.golden || g=testdata/user_data.prefix_off.golden
  terraform -chdir="$work" apply -auto-approve -var "prefix=$v" >/dev/null
  terraform -chdir="$work" output -raw ud > "$work/out.$v"
  first="$(head -n1 "$work/out.$v")"
  if [ "$first" != "MIME-Version: 1.0" ]; then echo "FAIL prefix=$v: line 1 is '$first' (must be exactly 'MIME-Version: 1.0', no indentation)"; rc=1; fi
  if grep -qE '^[[:space:]]+(MIME-Version|Content-Type|--BOUNDARY)' "$work/out.$v"; then echo "FAIL prefix=$v: indented MIME header/boundary"; rc=1; fi
  if ! cmp -s "$work/out.$v" "$g"; then echo "FAIL prefix=$v: bytes differ from $g"; diff <(cat -A "$g") <(cat -A "$work/out.$v") | head -20; rc=1
  else echo "ok   prefix=$v: line 1 exact, byte-identical to $g ($(wc -c < "$g") bytes)"; fi
done
exit $rc
