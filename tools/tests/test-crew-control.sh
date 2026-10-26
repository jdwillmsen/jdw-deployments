#!/usr/bin/env bash
# Renders the crew-lab chart and checks crew-control, the public console. Its
# unit list is rendered from crew.units, so a unit that is stopped must drop
# out of it, and its CPU limit counts against the same namespace quota the
# backup CronJobs need headroom in.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/crew-lab"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

render() {
  helm template crew-lab "$chart" --namespace jdwillmsen-prd \
    -f "$chart/values.yaml" -f "$chart/values-prd.yaml" "$@"
}

check='
import json, re, sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
dep = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "crew-control")
c = dep["spec"]["template"]["spec"]["containers"][0]
env = {e["name"]: e["value"] for e in c["env"] if "value" in e}
units = json.loads(env["CREW_UNITS"])
want = json.loads(sys.argv[2])
assert [u["id"] for u in units] == want, [u["id"] for u in units]
for u in units:
    assert u["url"] == "http://%s:8080" % u["id"], u
    assert set(u) == {"id", "name", "url"}, u
if len(sys.argv) > 3:
    sys.exit(0)

assert [u["name"] for u in units] == ["Agate", "Basalt", "Cobble", "Dusty", "Ember", "Flint", "Gravel", "Hazel", "Ingot", "Jasper", "Kettle", "Loam", "Marble", "Nugget", "Onyx", "Pebble", "Quartz", "Rusty", "Slate", "Tinder"], units
assert dep["spec"]["replicas"] == 1
assert dep["spec"]["strategy"]["type"] == "Recreate"
assert c["securityContext"]["readOnlyRootFilesystem"] is True
pod = dep["spec"]["template"]["spec"]
assert pod["securityContext"]["fsGroup"] == 1000
vols = {v["name"]: v for v in pod["volumes"]}
assert vols["data"]["persistentVolumeClaim"]["claimName"] == "crew-control"
assert vols["invites"]["secret"] == {"secretName": "crew-control-invites", "optional": True}, vols["invites"]
mounts = {m["name"]: m for m in c["volumeMounts"]}
assert mounts["data"]["mountPath"] == "/data" and not mounts["data"].get("readOnly")
assert mounts["invites"]["mountPath"] == "/invites" and mounts["invites"]["readOnly"] is True

assert env["PUBLIC_ORIGIN"] == "https://crew.prd.jdwlabs.com", env["PUBLIC_ORIGIN"]
assert json.loads(env["CREW_OPERATORS"]) == [{"id": "owner", "name": "Jake"}, {"id": "josh", "name": "Josh"}]
places = json.loads(env["CREW_PLACES"])
assert isinstance(places, list) and places, "CREW_PLACES must be a non-empty list"
ids = set()
chests = set()
for p in places:
    assert set(p) <= {"id", "name", "kind", "box", "items"}, p
    assert re.fullmatch(r"[a-z][a-z0-9-]{1,31}", p["id"]), p["id"]
    assert p["id"] not in ids, "duplicate " + p["id"]
    ids.add(p["id"])
    assert 0 < len(p["name"].strip()) <= 64, p
    lo, hi = p["box"]["min"], p["box"]["max"]
    for pos in (lo, hi):
        assert -500 <= pos["x"] <= 499 and -500 <= pos["z"] <= 499 and -64 <= pos["y"] <= 320, p
    assert all(lo[k] <= hi[k] for k in "xyz"), p
    if p["kind"] == "chest":
        assert lo == hi, p["id"] + ": a chest is one block"
        assert (lo["x"], lo["y"], lo["z"]) not in chests, p["id"] + ": two chests at one position"
        chests.add((lo["x"], lo["y"], lo["z"]))
    else:
        assert p["kind"] == "area", p
        assert all(hi[k] - lo[k] < 64 for k in "xyz"), p["id"] + ": area spans 64 or more"
    assert all(re.fullmatch(r"[a-z_]{1,32}", i) for i in p.get("items", [])), p
by = {p["id"]: p for p in places}
for pid, kind, items in [("quarry-1", "area", ["cobblestone"]), ("grove-1", "area", ["oak_log"]),
                         ("outbox-a", "chest", []), ("outbox-b", "chest", []), ("store", "chest", [])]:
    assert pid in by, pid + " is missing"
    assert by[pid]["kind"] == kind and by[pid].get("items", []) == items, by[pid]
assert env["CREW_INVITES_DIR"] == "/invites" and env["DATA_DIR"] == "/data"
assert "WORK_STORE" not in env
assert env["PG_HOST"] == "platform-postgresql-cluster-prd-rw.database.svc.cluster.local"
assert env["PG_PORT"] == "5432" and env["PG_DATABASE"] == "jdwillmsen_prd"
by = {e["name"]: e for e in c["env"]}
assert by["WORK_TOKEN"]["valueFrom"]["secretKeyRef"] == {"name": "crew-work", "key": "token", "optional": True}
for k in ("PG_USERNAME", "PG_PASSWORD"):
    assert by[k]["valueFrom"]["secretKeyRef"] == {"name": "crew-control-db", "key": k}, k

pvc = next(d for d in docs if d["kind"] == "PersistentVolumeClaim" and d["metadata"]["name"] == "crew-control")
assert pvc["spec"]["storageClassName"] == "truenas-nfs"
assert pvc["spec"]["accessModes"] == ["ReadWriteOnce"]
assert pvc["spec"]["resources"]["requests"]["storage"] == "64Mi"

es = next(d for d in docs if d["kind"] == "ExternalSecret" and d["metadata"]["name"] == "crew-control-db")
assert es["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"] == "-1"
assert es["spec"]["target"]["name"] == "crew-control-db"
assert sorted(x["secretKey"] for x in es["spec"]["data"]) == ["PG_PASSWORD", "PG_USERNAME"]

for u in want:
    ud = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == u)
    ue = {e["name"]: e for e in ud["spec"]["template"]["spec"]["containers"][0]["env"]}
    assert ue["CONTROL_URL"]["value"] == "http://crew-control:8080", u
    assert ue["CONTROL_TOKEN"]["valueFrom"]["secretKeyRef"] == {"name": "crew-work", "key": "token"}, u
assert c["livenessProbe"]["httpGet"]["path"] == "/healthz"
assert c["readinessProbe"]["httpGet"]["path"] == "/healthz"
assert c["image"] == "ghcr.io/jdwillmsen/minecraft-crew-control:1.17.0", c["image"]

cpu = c["resources"]["limits"]["cpu"]
milli = int(cpu[:-1]) if cpu.endswith("m") else int(float(cpu) * 1000)
assert milli <= 50, f"crew-control limits.cpu is {cpu}, want <= 50m"

svc = next(d for d in docs if d["kind"] == "Service" and d["metadata"]["name"] == "crew-control")
assert svc["spec"]["type"] == "ClusterIP"
assert svc["spec"]["selector"] == {"app": "crew-control"}
'

render > "$work/rendered.yaml"
python3 -c "$check" "$work/rendered.yaml" '["crew-01","crew-02","crew-03","crew-04","crew-05","crew-06","crew-07","crew-08","crew-09","crew-10","crew-11","crew-12","crew-13","crew-14","crew-15","crew-16","crew-17","crew-18","crew-19","crew-20"]' \
  || fail "crew-control is not rendered as expected"

render --set 'crew.units[1].replicas=0' > "$work/scaled.yaml"
python3 -c "$check" "$work/scaled.yaml" '["crew-01","crew-03","crew-04","crew-05","crew-06","crew-07","crew-08","crew-09","crew-10","crew-11","crew-12","crew-13","crew-14","crew-15","crew-16","crew-17","crew-18","crew-19","crew-20"]' skip \
  || fail "a stopped unit is still listed by crew-control"

stop_all=()
for i in $(seq 0 19); do stop_all+=(--set "crew.units[$i].replicas=0"); done
render "${stop_all[@]}" > "$work/empty.yaml"
python3 - "$work/empty.yaml" <<'PY' || fail "crew-control is not scaled to zero with no running units"
import sys, yaml
dep = next(d for d in yaml.safe_load_all(open(sys.argv[1]))
           if d and d["kind"] == "Deployment" and d["metadata"]["name"] == "crew-control")
assert dep["spec"]["replicas"] == 0, dep["spec"]["replicas"]
PY

render --set crew.control.enabled=false > "$work/off.yaml"
if grep -q "^  name: crew-control" "$work/off.yaml" && grep -q "^kind: \(Deployment\|Service\)" "$work/off.yaml" && grep -q "app: crew-control" "$work/off.yaml"; then
  fail "crew.control.enabled=false still renders crew-control"
fi

python3 - "$work/off.yaml" <<'PY' || fail "crew.control.enabled=false still renders crew-control"
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
left = [d["kind"] for d in docs
        if d["kind"] in ("Deployment", "Service", "PersistentVolumeClaim", "ExternalSecret")
        and d["metadata"]["name"] in ("crew-control", "crew-control-db")]
for d in docs:
    if d["kind"] == "Deployment" and d["metadata"]["name"].startswith("crew-"):
        names = [e["name"] for e in d["spec"]["template"]["spec"]["containers"][0]["env"]]
        assert "CONTROL_URL" not in names and "CONTROL_TOKEN" not in names, "units still point at a missing crew-control"
assert not left, left
PY

# The save reader mounts the game server's data claim read-only and must run
# on the game server's node, because the claim is ReadWriteOnce. Off, none of
# it may render, so the route falls back to live state alone.
world_check='
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
on = sys.argv[2] == "on"
dep = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "crew-control")
spec = dep["spec"]["template"]["spec"]
c = spec["containers"][0]
env = {e["name"]: e.get("value") for e in c["env"]}
vols = {v["name"]: v for v in spec["volumes"]}
mounts = {m["name"]: m for m in c["volumeMounts"]}
if on:
    assert env["CREW_WORLD_DB"] == "/world/worlds/crew-lab/db", env.get("CREW_WORLD_DB")
    assert env["CREW_WORLD_WORK"] == "/world-work"
    assert vols["world"]["persistentVolumeClaim"] == {"claimName": "datadir-crew-lab-minecraft-bedrock-0", "readOnly": True}, vols["world"]
    assert mounts["world"]["readOnly"] is True and mounts["world"]["mountPath"] == "/world"
    assert "emptyDir" in vols["world-work"] and not mounts["world-work"].get("readOnly")
    term = spec["affinity"]["podAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]
    assert term == [{"topologyKey": "kubernetes.io/hostname", "labelSelector": {"matchLabels": {"app": "crew-lab-minecraft-bedrock"}}}], term
else:
    assert not any(k.startswith("CREW_WORLD") for k in env), env
    assert "world" not in vols and "world-work" not in vols and "world" not in mounts
    assert "affinity" not in spec, spec.get("affinity")
'
render > "$work/world-on.yaml"
python3 -c "$world_check" "$work/world-on.yaml" on || fail "the world save is not mounted as expected"
render --set crew.control.world.enabled=false > "$work/world-off.yaml"
python3 -c "$world_check" "$work/world-off.yaml" off || fail "the world save wiring renders while disabled"

# The cluster scrapes crew-control through its Service; the public route does
# not carry /metrics (test-crew-route.sh), so this is the only path to it.
monitor_check='
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
mons = [d for d in docs if d["kind"] == "ServiceMonitor"]
if sys.argv[2] == "off":
    assert not mons, [m["metadata"]["name"] for m in mons]
    sys.exit(0)
assert len(mons) == 1, [m["metadata"]["name"] for m in mons]
m = mons[0]
assert m["metadata"]["name"] == "crew-control" and m["metadata"]["namespace"] == "jdwillmsen-prd"
assert m["spec"]["selector"] == {"matchLabels": {"app": "crew-control"}}
assert m["spec"]["namespaceSelector"] == {"matchNames": ["jdwillmsen-prd"]}
assert m["spec"]["endpoints"] == [{"port": "http", "path": "/metrics", "interval": "60s"}], m["spec"]["endpoints"]
svc = next(d for d in docs if d["kind"] == "Service" and d["metadata"]["name"] == "crew-control")
assert svc["metadata"]["labels"]["app"] == "crew-control"
assert [p["name"] for p in svc["spec"]["ports"]] == ["http"]
'
python3 -c "$monitor_check" "$work/rendered.yaml" on || fail "crew-control is not scraped as expected"
render --set crew.control.metrics.enabled=false > "$work/metrics-off.yaml"
python3 -c "$monitor_check" "$work/metrics-off.yaml" off || fail "crew.control.metrics.enabled=false still renders a ServiceMonitor"
python3 -c "$monitor_check" "$work/off.yaml" off || fail "crew.control.enabled=false still renders a ServiceMonitor"

echo "PASS: crew-control renders as expected"
