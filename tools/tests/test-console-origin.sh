#!/usr/bin/env bash
# Pins the console websocket's exposure boundary in the rendered chart.
#
# The console websocket is the one path that runs server commands. Its origin
# check is off, and the only reason that is defensible is the bind address: the
# endpoint listens on loopback inside the server pod and no Service publishes
# it, so the browser a Cross-Site WebSocket Hijacking attack needs has nothing
# to dial. That argument is a pair, not one setting, and nothing else in this
# repo notices if half of it moves -- helm renders a console bound to 0.0.0.0
# just as happily, and ArgoCD syncs it.
#
# The check cannot simply be turned on instead. mc-server-runner admits a
# request only when its literal Origin header appears in the allow-list, and
# the allow-list drops blank fields, so the empty string cannot be an entry --
# a client sending no Origin, which is what the bridge sidecar is, is refused
# under every possible allow-list. Enabling it needs a bridge that sends a
# fixed Origin, which is a change to the sidecar image and not to this chart.
# Until that ships, the assertions below are the control that is actually
# holding, so they are the ones worth failing a build over.
#
# Read from the rendered chart rather than from the values file, so an override
# arriving from any layer is caught rather than the one layer this was written
# against.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/minecraft-fwb"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# Two renders, because they answer different questions and neither covers the
# other.
#
# The first is values-console-bridge.yaml on its own: that file wires the
# console up, it ships in the chart whether or not anything applies it, and its
# settings are what this suite exists to pin. Asserted unconditionally.
helm template minecraft-fwb "$chart" \
  -f "$chart/values.yaml" \
  -f "$chart/values-console-bridge.yaml" > "$work/rendered.yaml"
[ -s "$work/rendered.yaml" ] || fail "the chart rendered nothing"

# The second is whatever the ArgoCD Application actually lists, read from the
# config rather than repeated here -- an overlay added later has to be able to
# move these settings and be caught, and a list copied into this file would not
# see it.
mapfile -t value_files < <(python3 -c "
import yaml
cfg = yaml.safe_load(open('$here/argocd/prd/config.yaml'))
for app in cfg['apps']:
    if app['chartPath'] == 'charts/minecraft-fwb':
        print('\n'.join(app['valueFiles']))
        break
")
[ "${#value_files[@]}" -gt 0 ] || fail "argocd/prd/config.yaml lists no value files for this chart"

args=()
for vf in "${value_files[@]}"; do
  args+=(-f "$chart/$vf")
done
helm template minecraft-fwb "$chart" "${args[@]}" > "$work/deployed.yaml"

cat > "$work/check-console.py" <<'CHECK'
import sys, yaml

rendered = sys.argv[1]
server = None
services = []
for doc in yaml.safe_load_all(open(rendered)):
    if not doc:
        continue
    if doc.get("kind") == "StatefulSet" and doc["metadata"]["name"].endswith("-minecraft-bedrock"):
        server = doc["spec"]["template"]["spec"]
    if doc.get("kind") == "Service":
        services.append(doc)

assert server, "no server StatefulSet rendered, so nothing below was checked"

containers = {c["name"]: c for c in server["containers"]}
game = next((c for n, c in containers.items() if n.endswith("minecraft-bedrock")), None)
assert game, f"no game server container among {sorted(containers)}"

env = {e["name"]: e for e in game.get("env") or []}

# Removing values-console-bridge.yaml from the ArgoCD Application is the
# documented way to back this feature out with the server already up, so a
# render without the console is a legitimate state, not a failure -- reporting
# it red would make that revert cost a CI fight during an incident. The caller
# decides whether "absent" is allowed for the render it passed in.
if env.get("WEBSOCKET_CONSOLE", {}).get("value") != "true":
    if len(sys.argv) > 2 and sys.argv[2] == "--may-be-absent":
        print("  ok: this render does not enable the console websocket, nothing to bound")
        sys.exit(0)
    raise AssertionError("the console websocket is not enabled, so these assertions cover nothing")

# The load-bearing one. Everything that makes a disabled origin check
# acceptable is this address: the console must be reachable only from inside
# the pod's own network namespace.
addr = env.get("WEBSOCKET_ADDRESS", {}).get("value")
assert addr, "the console websocket binds wherever mc-server-runner defaults to (0.0.0.0), not loopback"
host, _, port = addr.rpartition(":")
assert host in ("127.0.0.1", "localhost", "[::1]"), (
    f"the console websocket binds {host!r}, not loopback: with the origin check "
    "off this publishes a command-execution endpoint to the pod network"
)

# Nothing may carry that port out of the pod. A Service in front of it reaches
# past the loopback bind the argument above depends on.
for svc in services:
    for p in svc["spec"].get("ports") or []:
        assert str(p.get("targetPort")) != port and str(p.get("port")) != port, (
            f"Service {svc['metadata']['name']} publishes the console websocket port {port}"
        )

# Declaring it as a containerPort does not open it either, but it is how a
# console port gets picked up by anything scanning the workload for endpoints,
# and it contradicts the loopback-only claim the comments make.
for name, c in containers.items():
    for p in c.get("ports") or []:
        assert str(p.get("containerPort")) != port, (
            f"container {name} declares the console websocket port {port} as a containerPort"
        )

disabled = env.get("WEBSOCKET_DISABLE_ORIGIN_CHECK", {}).get("value")
allowed = env.get("WEBSOCKET_ALLOWED_ORIGINS", {}).get("value")

# Turning the check on without giving the bridge an Origin it can send is not a
# hardening, it is an outage: every dial the sidecar makes comes back 403 and
# the console path stops working entirely. Allow this only once the allow-list
# names something, which is the shape the fix will take.
if disabled != "true":
    assert allowed, (
        "the origin check is enabled with no allow-list, which refuses every "
        "client including the bridge sidecar -- the console path is dead"
    )

# An allow-list alongside a disabled check is inert, and reads as protection
# that is not there.
if disabled == "true":
    assert not allowed, (
        "WEBSOCKET_ALLOWED_ORIGINS is set while the origin check is disabled, "
        "so it is ignored while looking like it applies"
    )

# The server compares by exact string equality, so the two literals drifting
# apart locks the bridge out of its own console -- and does it silently, since
# each half reads as correct on its own.
if allowed:
    sidecar = None
    for c in containers.values():
        for e in c.get("env") or []:
            if e.get("name") == "CONSOLE_ORIGIN":
                sidecar = e.get("value")
    assert sidecar is not None, (
        "the server allow-lists an origin but no container sends one: the "
        "bridge dials without an Origin and is refused by every entry"
    )
    assert sidecar == allowed, (
        f"the bridge sends Origin {sidecar!r} but the server allow-lists "
        f"{allowed!r}; exact string equality means the bridge is locked out"
    )

print("  ok: console on loopback, unpublished, and its origin settings agree with each other")
CHECK

python3 "$work/check-console.py" "$work/rendered.yaml" \
  || fail "values-console-bridge.yaml does not bound the console websocket the way its comments claim"

python3 "$work/check-console.py" "$work/deployed.yaml" --may-be-absent \
  || fail "the value files argocd/prd/config.yaml lists render a console websocket that is not bounded"

# Negative controls. Each flips one field in a copy of the render; a check that
# stays green on any of them is asserting nothing.
mutate() {
  python3 - "$work/rendered.yaml" "$work/mutant-$1.yaml" "$1" <<'MUTATE'
import sys, yaml

src, dst, which = sys.argv[1], sys.argv[2], sys.argv[3]
docs = list(yaml.safe_load_all(open(src)))
touched = 0
for doc in docs:
    if not doc:
        continue
    if doc.get("kind") == "StatefulSet" and doc["metadata"]["name"].endswith("-minecraft-bedrock"):
        spec = doc["spec"]["template"]["spec"]
        game = next(c for c in spec["containers"] if c["name"].endswith("minecraft-bedrock"))
        env = {e["name"]: e for e in game["env"]}
        if which == "bind-all-interfaces":
            env["WEBSOCKET_ADDRESS"]["value"] = "0.0.0.0:8765"
            touched += 1
        if which == "check-on-with-no-allowlist":
            game["env"] = [e for e in game["env"] if e.get("name") != "WEBSOCKET_ALLOWED_ORIGINS"]
            touched += 1
        if which == "origin-drift":
            for e in game["env"]:
                if e.get("name") == "WEBSOCKET_ALLOWED_ORIGINS":
                    e["value"] = "https://example.invalid"
            touched += 1
        if which == "console-port-declared":
            game.setdefault("ports", []).append({"name": "ws-console", "containerPort": 8765})
            touched += 1
    if which == "console-published" and doc.get("kind") == "Service" \
            and doc["metadata"]["name"].endswith("-console-bridge"):
        doc["spec"]["ports"].append({"name": "ws-console", "port": 8765, "targetPort": 8765})
        touched += 1
assert touched == 1, f"mutation {which} matched {touched} places, so it is not the mutation it claims"
with open(dst, "w") as fh:
    yaml.safe_dump_all(docs, fh)
MUTATE
}

for mutation in bind-all-interfaces check-on-with-no-allowlist origin-drift \
                console-port-declared console-published; do
  mutate "$mutation"
  if python3 "$work/check-console.py" "$work/mutant-$mutation.yaml" >/dev/null 2>&1; then
    fail "the console check passes a render mutated to $mutation, so it does not check that"
  fi
  echo "  ok: the check rejects $mutation"
done

echo "PASS"
