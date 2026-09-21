#!/usr/bin/env bash
# Pins the console bridge to a liveness probe and no readiness probe.
#
# The bridge serves both /healthz and /readyz, and /readyz is the more
# informative of the two: it answers whether the console websocket is actually
# established. Wiring it to a readinessProbe is the obvious next step, reads as
# an improvement, and would be an outage.
#
# The bridge is a sidecar in the server's own pod, and readiness is a property
# of the pod rather than the container. Five Services select that pod --
# minecraft-bedrock and nethernet on the game port, join-probe-target,
# mc-monitor, console-bridge -- so a bridge that lost its console would take
# the game server out of every one of them and disconnect every player, to
# report a fault in a sidecar nobody was playing through.
#
# Nothing else notices: helm renders a readinessProbe just as happily, ArgoCD
# syncs it, and the pod stays Ready until the day the console drops.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/minecraft-fwb"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template minecraft-fwb "$chart" \
  -f "$chart/values.yaml" \
  -f "$chart/values-console-bridge.yaml" > "$work/rendered.yaml"
[ -s "$work/rendered.yaml" ] || fail "the chart rendered nothing"

cat > "$work/check-probes.py" <<'CHECK'
import sys, yaml

bridge = None
selectors = 0
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if not doc:
        continue
    if doc.get("kind") == "StatefulSet" and doc["metadata"]["name"].endswith("-minecraft-bedrock"):
        for c in doc["spec"]["template"]["spec"]["containers"]:
            if c["name"] == "console-bridge":
                bridge = c
    if doc.get("kind") == "Service":
        sel = (doc["spec"].get("selector") or {}).values()
        if any("minecraft-bedrock" in str(v) for v in sel):
            selectors += 1

assert bridge, "no console-bridge container rendered, so nothing below was checked"

# Stated rather than assumed: the argument against a readinessProbe rests on
# the pod being behind more than one Service, so if that ever stops being true
# the reasoning deserves revisiting rather than silently still passing.
assert selectors > 1, (
    f"only {selectors} Service selects the server pod; the readiness argument "
    "below assumed several, so re-read it before trusting this test"
)

assert bridge.get("readinessProbe") is None, (
    "the console bridge has a readinessProbe. Readiness is a pod-level "
    f"property and {selectors} Services select this pod, so a bridge that "
    "lost its console would evict the game server from all of them and "
    "disconnect every player. Alert on the console being down; do not gate "
    "the pod on it."
)

live = bridge.get("livenessProbe")
assert live, "the console bridge has no livenessProbe, so a wedged HTTP server is never restarted"
path = (live.get("httpGet") or {}).get("path")
assert path == "/healthz", (
    f"liveness probes {path!r}. /healthz answers for the process and stays "
    "green while the console is down, which is what makes it safe here; "
    "/readyz would restart the container for an outage a restart cannot fix"
)

print(f"  ok: console bridge is live-probed on /healthz and not readiness-gated ({selectors} Services select the pod)")
CHECK

python3 "$work/check-probes.py" "$work/rendered.yaml" || fail "the rendered chart does not satisfy the check"

mutate() {
  local which="$1"
  python3 - "$work/rendered.yaml" "$work/mutant-$which.yaml" "$which" <<'MUTATE'
import sys, yaml

src, dst, which = sys.argv[1], sys.argv[2], sys.argv[3]
docs = [d for d in yaml.safe_load_all(open(src)) if d]
touched = 0
for doc in docs:
    if doc.get("kind") != "StatefulSet" or not doc["metadata"]["name"].endswith("-minecraft-bedrock"):
        continue
    for c in doc["spec"]["template"]["spec"]["containers"]:
        if c["name"] != "console-bridge":
            continue
        if which == "readiness-added":
            c["readinessProbe"] = {"httpGet": {"path": "/readyz", "port": "bridge-http"}}
            touched += 1
        if which == "liveness-removed":
            c.pop("livenessProbe", None)
            touched += 1
        if which == "liveness-on-readyz":
            c["livenessProbe"]["httpGet"]["path"] = "/readyz"
            touched += 1
assert touched == 1, f"mutation {which} matched {touched} places, so it is not the mutation it claims"
with open(dst, "w") as fh:
    yaml.safe_dump_all(docs, fh)
MUTATE
}

for mutation in readiness-added liveness-removed liveness-on-readyz; do
  mutate "$mutation"
  if python3 "$work/check-probes.py" "$work/mutant-$mutation.yaml" >/dev/null 2>&1; then
    fail "the check passes a render mutated to $mutation, so it does not check that"
  fi
  echo "  ok: the check rejects $mutation"
done

echo "PASS"
