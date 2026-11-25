#!/usr/bin/env bash
# Playground disk rule: the kodekloud env must not render gp3, and its node root volume must be
# at most 20 GiB. Offline (helm + python3 yaml). Usage: scripts/check-env-disk.sh [repo-dir]
set -euo pipefail
cd "${1:-$(dirname "$0")/..}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
helm template root platform/apps -f platform/apps/values.yaml -f platform/apps/values-kodekloud.yaml > "$work/apps.yaml"
cls="$(python3 -I -c '
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d["kind"] == "Application" and d["metadata"]["name"] == "storage":
        print({p["name"]: p["value"] for p in d["spec"]["source"]["helm"]["parameters"]}["defaultClass"])
' "$work/apps.yaml")"
[ -n "$cls" ] || { echo "FAIL: storage Application passes no defaultClass"; exit 1; }
helm template storage platform/storage --set "defaultClass=$cls" > "$work/sc.yaml"
python3 -I - "$work/sc.yaml" infra/terraform <<'PY'
import sys, re, yaml
def fail(m): print("FAIL:", m); sys.exit(1)
scs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
for d in scs:
    if "gp3" in (d["metadata"]["name"], d["parameters"]["type"]): fail(f"kodekloud renders a gp3 StorageClass ({d['metadata']['name']})")
default = [d for d in scs if d["metadata"]["annotations"]["storageclass.kubernetes.io/is-default-class"] == "true"]
if len(default) != 1 or default[0]["parameters"]["type"] != "gp2": fail("kodekloud needs exactly one default StorageClass, of type gp2")
tf = sys.argv[2]
v = dict(re.findall(r'^\s*(node_volume_\w+)\s*=\s*"?(\w+)"?', open(tf + "/envs/kodekloud.tfvars").read(), re.M))
if v.get("node_volume_type") != "gp2": fail(f"kodekloud.tfvars node_volume_type is {v.get('node_volume_type')}, need gp2")
if not v.get("node_volume_size", "").isdigit() or int(v["node_volume_size"]) > 20: fail(f"kodekloud.tfvars node_volume_size is {v.get('node_volume_size')}, need <= 20")
n = open(tf + "/nodes.tf").read()
for k in ("size", "type"):
    if not re.search(rf'volume_{k}\s*=\s*var\.node_volume_{k}\b', n): fail(f"nodes.tf does not use var.node_volume_{k}")
print(f"ok   kodekloud disks: default StorageClass {default[0]['metadata']['name']} (gp2), no gp3 class, root gp2 {v['node_volume_size']}GiB")
PY
