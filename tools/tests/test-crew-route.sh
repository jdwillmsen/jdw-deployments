#!/usr/bin/env bash
# Renders the crew-lab chart and checks that its public route stays view-only.
# The task API, /metrics and the probes share the unit's port, so a route that
# reaches any of them hands a public hostname the ability to make crew act.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/crew-lab"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template crew-lab "$chart" --namespace jdwillmsen-prd \
  -f "$chart/values.yaml" -f "$chart/values-prd.yaml" > "$work/rendered.yaml"

python3 - "$work/rendered.yaml" <<'PY' || fail "the crew route is not view-only"
import sys, yaml

routes = [d for d in yaml.safe_load_all(open(sys.argv[1]))
          if d and d.get("kind") == "HTTPRoute"]
assert len(routes) == 1, f"want one HTTPRoute, got {len(routes)}"
spec = routes[0]["spec"]
assert spec["hostnames"] == ["crew.prd.jdwlabs.com"], spec["hostnames"]

def reachable(path):
    for rule in spec["rules"]:
        if not rule.get("backendRefs"):
            continue
        for m in rule.get("matches", [{"path": {"type": "PathPrefix", "value": "/"}}]):
            p = m.get("path", {"type": "PathPrefix", "value": "/"})
            v = p["value"]
            if p["type"] == "Exact" and path == v:
                return True
            if p["type"] == "PathPrefix" and (path == v or path.startswith(v.rstrip("/") + "/")):
                return True
            if p["type"] not in ("Exact", "PathPrefix"):
                raise AssertionError(f"unexpected match type {p['type']}")
    return False

for path in ["/camera", "/v1/state", "/v1/camera/ws", "/v1/camera/atlas.json", "/v1/camera/atlas.png"]:
    assert reachable(path), f"{path} should be routed"
for path in ["/v1/tasks", "/v1/tasks/abc/cancel", "/metrics", "/healthz", "/readyz", "/v1/statex", "/v1/camerax"]:
    assert not reachable(path), f"{path} must not be routed"
PY

# With the route off, nothing public is rendered at all.
helm template crew-lab "$chart" --namespace jdwillmsen-prd \
  -f "$chart/values.yaml" -f "$chart/values-prd.yaml" \
  --set crew.route.enabled=false > "$work/off.yaml"
if grep -q '^kind: HTTPRoute' "$work/off.yaml"; then
  fail "crew.route.enabled=false still renders an HTTPRoute"
fi

echo "PASS: crew route is view-only"
