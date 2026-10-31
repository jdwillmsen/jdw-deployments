#!/usr/bin/env bash
# Renders the crew-test chart and checks that the test server is a separate,
# NetherNet-only, node-pinned server that cannot collide with the lab or the
# main server. The release names are the ones ArgoCD generates (the owner
# prefix plus the app name), because every object name derives from them.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
test_chart="$here/charts/crew-test"
lab_chart="$here/charts/crew-lab"
fwb_chart="$here/charts/minecraft-fwb"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template jdwillmsen-crew-test-prd "$test_chart" --namespace jdwillmsen-prd \
  -f "$test_chart/values.yaml" -f "$test_chart/values-prd.yaml" > "$work/test.yaml"
helm template jdwillmsen-crew-lab-prd "$lab_chart" --namespace jdwillmsen-prd \
  -f "$lab_chart/values.yaml" -f "$lab_chart/values-prd.yaml" > "$work/lab.yaml"
helm template jdwillmsen-minecraft-fwb-prd "$fwb_chart" --namespace jdwillmsen-prd \
  -f "$fwb_chart/values.yaml" -f "$fwb_chart/values-prd.yaml" \
  -f "$fwb_chart/values-console-bridge.yaml" -f "$fwb_chart/values-map-pack.yaml" > "$work/fwb.yaml"

python3 - "$work/test.yaml" <<'PY' || fail "the test server is not what the owner joins"
import sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
kinds = sorted((d["kind"], d["metadata"]["name"]) for d in docs)
want = [
    ("Service", "jdwillmsen-crew-test-prd-minecraft-bedrock"),
    ("Service", "jdwillmsen-crew-test-prd-nethernet"),
    ("StatefulSet", "jdwillmsen-crew-test-prd-minecraft-bedrock"),
]
# Nothing else: no crew units or control plane, no CronJob (so no version
# check that would restart a pinned server every hour), no ConfigMap.
assert kinds == want, f"want exactly {want}, got {kinds}"

sts = next(d for d in docs if d["kind"] == "StatefulSet")
pod = sts["spec"]["template"]["spec"]
server = pod["containers"][0]
assert len(pod["containers"]) == 1, "the server is the only container"
env = {e["name"]: e.get("value") for e in server["env"]}

# Transport, ports and the node address the client is handed.
assert env["TRANSPORT"] == "nethernet", env["TRANSPORT"]
assert env["SERVER_PORT"] == "31200", env["SERVER_PORT"]
assert env["SERVER_UDP_PORTS"] == "192.168.1.163:31210-31229:31210-31229", env["SERVER_UDP_PORTS"]

# Pinned to one node, the one whose address SERVER_UDP_PORTS advertises.
terms = pod["affinity"]["nodeAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]["nodeSelectorTerms"]
assert terms == [{"matchExpressions": [{"key": "kubernetes.io/hostname", "operator": "In", "values": ["talos-lx0-6a4"]}]}], terms

# Version pinned: LATEST is ahead of the Windows client.
assert env["VERSION"] == "1.26.60.6", env["VERSION"]

# A fresh creative flat world that signed-in players can join and cheat in.
assert env["LEVEL_NAME"] == "crew-test" and env["LEVEL_TYPE"] == "FLAT", (env["LEVEL_NAME"], env["LEVEL_TYPE"])
assert env["GAMEMODE"] == "creative" and env["ALLOW_CHEATS"] == "true", (env["GAMEMODE"], env["ALLOW_CHEATS"])
assert env["ONLINE_MODE"] == "true", env["ONLINE_MODE"]
assert env["OPS"] == "", "no operator is preset; permissions are keyed by XUID"
vct = sts["spec"]["volumeClaimTemplates"][0]
assert vct["spec"]["storageClassName"] == "truenas-iscsi", vct["spec"]["storageClassName"]
assert vct["spec"]["resources"]["requests"]["storage"] == "5Gi", vct["spec"]["resources"]

# NetherNet answers no RakNet ping: startup probe off, liveness a year out,
# readiness left to fail (the Service publishes not-ready addresses).
assert "startupProbe" not in server, "a startup probe would kill a healthy NetherNet server"
assert server["livenessProbe"]["initialDelaySeconds"] == 31536000, server["livenessProbe"]
assert "readinessProbe" in server

# Quota: the namespace has to keep headroom for the 2000m of CronJob limits.
def milli(v):
    v = str(v)
    return int(v[:-1]) if v.endswith("m") else int(float(v) * 1000)
# 2950m was free for 2000m of jobs: only 750m leaves them room
assert server["resources"]["limits"]["cpu"] == "750m", server["resources"]["limits"]
assert server["resources"]["limits"]["memory"] == "1Gi", server["resources"]["limits"]
# open on purpose: a list would refuse every account the owner signs in with
assert env["ALLOW_LIST"] == "false", env.get("ALLOW_LIST")

# The lab-packs hook installs into the world the server creates.
init = pod["initContainers"]
assert [i["name"] for i in init] == ["install-lab-packs"], [i["name"] for i in init]
assert init[0]["args"] == ["/data/worlds/" + env["LEVEL_NAME"]], init[0]["args"]
image = init[0]["image"]
assert image.startswith("ghcr.io/jdwillmsen/lab-packs:") and not image.endswith(":latest"), image
assert init[0]["resources"]["limits"]["cpu"] == "50m" and init[0]["resources"]["limits"]["memory"] == "64Mi"

svcs = {d["metadata"]["name"]: d for d in docs if d["kind"] == "Service"}
raknet = svcs["jdwillmsen-crew-test-prd-minecraft-bedrock"]["spec"]
assert raknet["type"] == "NodePort"
assert [(p["protocol"], p["port"], p["nodePort"]) for p in raknet["ports"]] == [("UDP", 31200, 31200)], raknet["ports"]

nn = svcs["jdwillmsen-crew-test-prd-nethernet"]["spec"]
assert nn["type"] == "NodePort" and nn["publishNotReadyAddresses"] is True, nn
assert nn["selector"] == {"app": "jdwillmsen-crew-test-prd-minecraft-bedrock"}, nn["selector"]
signaling = [p for p in nn["ports"] if p["protocol"] == "TCP"]
assert [(p["port"], p["targetPort"], p["nodePort"]) for p in signaling] == [(31200, 31200, 31201)], signaling
udp = [p for p in nn["ports"] if p["protocol"] == "UDP"]
assert [p["port"] for p in udp] == list(range(31210, 31230)), [p["port"] for p in udp]
assert all(p["targetPort"] == p["port"] == p["nodePort"] for p in udp), "gameplay ports must map one to one"
assert len(nn["ports"]) == 21 and len({p["name"] for p in nn["ports"]}) == 21
PY

# Collision audit across everything else in the namespace. Two releases in one
# namespace fail to sync on a repeated (kind, name), and a NodePort number is
# taken whatever its protocol (the chart's own 31201 note rests on that), so
# both are checked against the lab and the main server, whatever their transport.
python3 - "$work/test.yaml" "$work/lab.yaml" "$work/fwb.yaml" <<'PY' || fail "the test server collides with another release"
import sys, yaml

def load(path):
    return [d for d in yaml.safe_load_all(open(path)) if d]

def claims(docs):
    for d in docs:
        if d["kind"] == "StatefulSet":
            for t in d["spec"].get("volumeClaimTemplates", []):
                yield f"{t['metadata']['name']}-{d['metadata']['name']}-0"

def node_ports(docs):
    for d in docs:
        if d["kind"] == "Service":
            for p in d["spec"].get("ports", []):
                if p.get("nodePort"):
                    yield p["nodePort"]

test, others = load(sys.argv[1]), [load(p) for p in sys.argv[2:]]
assert test and all(others), "an empty render makes the audit vacuous"
mine = {(d["kind"], d["metadata"]["name"], d["metadata"].get("namespace")) for d in test}
mine |= {("PersistentVolumeClaim", c, "jdwillmsen-prd") for c in claims(test)}
for docs in others:
    theirs = {(d["kind"], d["metadata"]["name"], d["metadata"].get("namespace")) for d in docs}
    theirs |= {("PersistentVolumeClaim", c, "jdwillmsen-prd") for c in claims(docs)}
    both = sorted(mine & theirs)
    assert not both, f"same kind and name as another release: {both}"
    shared = sorted(set(node_ports(test)) & set(node_ports(docs)))
    assert not shared, f"same NodePort as another release: {shared}"

# Within the chart itself: one (kind, name) each.
keys = [(d["kind"], d["metadata"]["name"]) for d in test]
assert len(keys) == len(set(keys)), keys
PY

# Its own ArgoCD app, so a sync of the lab or the main server never includes
# this chart. The wave records the intent to come after the lab; it orders
# nothing without a parent app.
python3 - "$here/argocd/prd/config.yaml" <<'PY' || fail "the argo app is not a separate, later wave"
import sys, yaml

apps = {a["name"]: a for a in yaml.safe_load(open(sys.argv[1]))["apps"]}
app = apps["crew-test-prd"]
assert app["chartPath"] == "charts/crew-test" and app["namespace"] == "jdwillmsen-prd", app
assert app["valueFiles"] == ["values.yaml", "values-prd.yaml"], app["valueFiles"]
assert int(app["syncWave"]) > int(apps["crew-lab-prd"]["syncWave"]), "the wave records that it follows the lab"
assert [n for n, a in apps.items() if a["chartPath"] == app["chartPath"]] == ["crew-test-prd"], "chart is shared with another app"
PY

# The add-on installer is the lab's image at the lab's tag, not one of its own.
python3 - "$work/test.yaml" "$work/lab.yaml" <<'PY' || fail "the lab-packs image differs from the lab's"
import sys, yaml

def packs(path):
    for d in yaml.safe_load_all(open(path)):
        if d and d["kind"] == "StatefulSet" and d["metadata"]["name"].endswith("-minecraft-bedrock"):
            for i in d["spec"]["template"]["spec"].get("initContainers", []):
                if i["name"] == "install-lab-packs":
                    return i["image"]
test, lab = packs(sys.argv[1]), packs(sys.argv[2])
assert test and lab and test == lab, (test, lab)
PY

echo "PASS: crew-test is a separate NetherNet server with no collisions"
