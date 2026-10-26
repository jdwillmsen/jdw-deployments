#!/usr/bin/env bash
# Renders the crew-lab chart and checks that its public route stays view-only.
# The task API, /metrics and the probes share each unit's port, so a route that
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
import re, sys, yaml

routes = [d for d in yaml.safe_load_all(open(sys.argv[1]))
          if d and d.get("kind") == "HTTPRoute"]
assert len(routes) == 1, f"want one HTTPRoute, got {len(routes)}"
spec = routes[0]["spec"]
assert spec["hostnames"] == ["crew.prd.jdwlabs.com"], spec["hostnames"]

for rule in spec["rules"]:
    for b in rule.get("backendRefs", []):
        assert b["name"] == "crew-control", f"backend {b['name']} is not crew-control"
    assert not any(f.get("type") == "RequestRedirect" for f in rule.get("filters", [])), "unexpected redirect"

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
            if p["type"] == "RegularExpression" and re.fullmatch(v, path):
                return True
            if p["type"] not in ("Exact", "PathPrefix", "RegularExpression"):
                raise AssertionError(f"unexpected match type {p['type']}")
    return False

for path in ["/", "/camera", "/units/crew-01/camera", "/units/crew-01/v1/state", "/units/crew-01/v1/camera/ws", "/v1/units/stream", "/v1/squads/stream", "/signin", "/auth/login/options", "/v1/work/crew-01/stop", "/v1/jobs", "/v1/jobs/abc/cancel", "/v1/places", "/v1/heatmap", "/static/console.js", "/v1/insights", "/v1/capacity", "/v1/units/crew-01/explain", "/v1/units/crew-01/inventory/changes", "/v1/events", "/v1/replay/positions", "/v1/alerts", "/v1/alerts/stream", "/v1/alerts/abc/ack", "/v1/alerts/abc/mute", "/v1/explorer/events", "/v1/explorer/tail", "/v1/explorer/views"]:
    assert reachable(path), f"{path} should be routed"
for path in ["/v1/tasks", "/v1/units/crew-01/work", "/v1/units/crew-01/events", "/v1/squads", "/v1/squads/alpha", "/v1/squads/alpha/orders", "/v1/squads/alpha/hello", "/v1/squadsx", "/v1/units", "/signinx", "/v1/workx", "/v1/jobsx", "/v1/placesx", "/v1/insightsx", "/v1/capacityx", "/v1/capacity/x", "/v1/units/crew-01/explainx", "/v1/units/crew-01/x/explain", "/v1/units//explain", "/v1/units/crew-01/explain/work", "/v1/units/crew-01/inventory/changesx", "/v1/units/crew-01/inventory", "/v1/events/prune", "/v1/eventsx", "/v1/replay", "/v1/replay/positionsx", "/v1/alertsx", "/v1/alerts/x", "/v1/alerts/abc/delete", "/v1/alerts/abc/ack/x", "/v1/explorerx", "/v1/replay/positions/x", "/v1/units/crew-01/x/inventory/changes", "/v1/heatmapx", "/v1/heatmap/x", "/v1/tasks/abc/cancel", "/metrics", "/metrics/", "/metrics/fleet", "/healthz", "/readyz", "/v1/state", "/v1/camera/ws", "/unitsx", "/v1/unitsx", "/staticx"]:
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
