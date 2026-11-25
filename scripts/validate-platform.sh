#!/usr/bin/env bash
# Offline checks for the platform chart (per environment), the ApplicationSet service sets and the
# gateway chart, validated against the CRD schemas of the pinned Envoy Gateway chart.
# Needs helm, python3 with yaml + jsonschema, and network once to pull the chart.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/check-no-ip.sh
scripts/check-env-disk.sh
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
ver="$(python3 -I -c 'import yaml;print(yaml.safe_load(open("platform/apps/values.yaml"))["charts"]["envoyGateway"]["version"])')"
tgz="${EG_CHART_TGZ:-}"
[ -n "$tgz" ] || { timeout 90 helm pull oci://docker.io/envoyproxy/gateway-helm --version "$ver" -d "$work" >/dev/null 2>&1; tgz="$work/gateway-helm-$ver.tgz"; }
helm template eg "$tgz" --include-crds -n envoy-gateway-system -f platform/values/envoy-gateway.yaml > "$work/crds.yaml"
for e in kodekloud personal; do
  helm template root platform/apps -f platform/apps/values.yaml -f "platform/apps/values-$e.yaml" > "$work/apps-$e.yaml"
done
helm template gw platform/gateway -n envoy-gateway-system > "$work/gw-closed.yaml"
helm template gw platform/gateway -n envoy-gateway-system --set admin.detectedCidr=203.0.113.7/32 > "$work/gw-open.yaml"
for bad in 0.0.0.0/0 10.0.0.0/8 not-an-ip; do
  if helm template gw platform/gateway --set "admin.detectedCidr=$bad" >/dev/null 2>&1; then echo "FAIL: CIDR $bad accepted"; exit 1; fi
done
echo "ok   bad admin CIDRs are refused"
scripts/test-env.sh render main browse > "$work/test-browse.yaml"
scripts/test-env.sh render main order > "$work/test-order.yaml"
python3 -I - "$work" <<'PY'
import sys, yaml, jsonschema, os
w = sys.argv[1]
load = lambda f: [d for d in yaml.load_all(open(os.path.join(w, f)), Loader=yaml.CSafeLoader) if d]
def fail(m): print("FAIL:", m); sys.exit(1)
def ok(m): print("ok  ", m)

# 1. gateway objects against CRD schemas (unknown fields rejected)
schemas = {}
for d in load("crds.yaml"):
    if d["kind"] == "CustomResourceDefinition":
        for v in d["spec"]["versions"]:
            schemas[(d["spec"]["group"] + "/" + v["name"], d["spec"]["names"]["kind"])] = v["schema"]["openAPIV3Schema"]
def strict(s):
    if isinstance(s, dict):
        if s.get("x-kubernetes-int-or-string"): return {"type": ["integer", "string"]}
        out = {k: strict(v) for k, v in s.items()}
        if "properties" in out and "additionalProperties" not in out and not s.get("x-kubernetes-preserve-unknown-fields"):
            out["additionalProperties"] = False
        return out
    return [strict(x) for x in s] if isinstance(s, list) else s
for f in ("gw-closed.yaml", "gw-open.yaml"):
    n = 0
    for d in load(f):
        if d["apiVersion"] == "v1": continue
        s = strict(schemas[(d["apiVersion"], d["kind"])])
        s["properties"]["metadata"] = {"type": "object"}
        errs = list(jsonschema.Draft7Validator(s).iter_errors(d))
        if errs: fail(f"{f} {d['kind']}/{d['metadata']['name']}: {errs[0].message[:200]} at {list(errs[0].path)}")
        n += 1
    ok(f"{f}: {n} gateway API objects match the CRD schemas")

# 2. fail closed / allow-list
kinds = lambda f: [(d["kind"], d["metadata"]["name"]) for d in load(f)]
c = kinds("gw-closed.yaml")
if ("Gateway", "admin") in c or ("HTTPRoute", "argocd") in c: fail("admin entrance rendered without a CIDR")
ok("no CIDR -> no admin Gateway or routes (fail closed)")
adm = [d for d in load("gw-open.yaml") if d["kind"] == "EnvoyProxy" and d["metadata"]["name"] == "admin"]
if adm[0]["spec"]["provider"]["kubernetes"]["envoyService"].get("loadBalancerSourceRanges") != ["203.0.113.7/32"]:
    fail("admin source ranges missing")
ok("CIDR -> admin load balancer restricted to exactly that CIDR")

# 3. paths agree with BASE_URL and the admin sub-path settings
gw = yaml.safe_load(open("platform/gateway/values.yaml"))
for r in gw["public"]["routes"]:
    env = r["namespace"].removeprefix("shop-")
    fv = yaml.safe_load(open(f"apps/online-boutique/frontend/values-{env}.yaml"))
    base = (fv.get("env") or {}).get("BASE_URL", "")
    if base != r["path"].rstrip("/"): fail(f"route {r['path']} != BASE_URL '{base}' ({env})")
    if base and fv["readinessProbe"]["path"] != base + "/_healthz": fail(f"{env} probe path does not include BASE_URL")
a = yaml.safe_load(open("platform/values/argocd.yaml"))["configs"]["params"]
g = yaml.safe_load(open("platform/values/kube-prometheus-stack.yaml"))["grafana"]["grafana.ini"]["server"]
paths = {r["name"]: r["path"] for r in gw["admin"]["routes"]}
if not (a["server.rootpath"] == a["server.basehref"] == paths["argocd"]): fail("argocd sub-path mismatch")
if not g["root_url"].endswith(paths["grafana"] + "/"): fail("grafana sub-path mismatch")
ok("route paths match BASE_URL, probe paths and admin sub-path settings")

# 4. service sets
def elements(f):
    d = [x for x in load(f) if x["kind"] == "ApplicationSet"][0]
    out = {}
    for e in d["spec"]["generators"][0]["list"]["elements"]: out.setdefault(e["env"], []).append(e["service"])
    return out
for f, want in (("apps-kodekloud.yaml", {"dev": 8, "prod": 9}), ("apps-personal.yaml", {"dev": 12, "test": 12, "prod": 12}),
                ("test-browse.yaml", {"test": 6}), ("test-order.yaml", {"test": 8})):
    got = {k: len(v) for k, v in elements(f).items()}
    if got != want: fail(f"{f}: {got} != {want}")
    for env, svcs in elements(f).items():
        for s in svcs:
            if not os.path.exists(f"apps/online-boutique/{s}/values-{env}.yaml"): fail(f"missing values for {s}/{env}")
    ok(f"{f}: {got}")
kps = lambda f: [s for d in load(f) if d["kind"] == "Application" and d["metadata"]["name"] == "kube-prometheus-stack"
                 for s in d["spec"]["sources"][0]["helm"]["valueFiles"]]
if len(kps("apps-kodekloud.yaml")) != 2 or len(kps("apps-personal.yaml")) != 1: fail("node-exporter override wiring")
ok("node-exporter override applied for kodekloud only")
PY
