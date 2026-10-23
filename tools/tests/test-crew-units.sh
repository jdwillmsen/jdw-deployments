#!/usr/bin/env bash
# Renders the crew-lab chart and checks the crew units: one Deployment, Service
# and PVC per unit, a shared task token, a kit chest to rearm from,
# the squad role and squad carried on the warriors' pods only, and a total CPU
# limit that leaves the namespace quota headroom for the backup and recovery
# CronJobs.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/crew-lab"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template crew-lab "$chart" --namespace jdwillmsen-prd \
  -f "$chart/values.yaml" -f "$chart/values-prd.yaml" > "$work/rendered.yaml"

python3 - "$work/rendered.yaml" <<'PY' || fail "the crew units are not rendered as expected"
import json, sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]

def of(kind):
    return [d for d in docs if d.get("kind") == kind]

# The lab server's own StatefulSet/Service carry no crew label.
crew = lambda kind: [d for d in of(kind)
                     if d["metadata"].get("labels", {}).get("app.kubernetes.io/component") == "crew"]

want = {"crew-01": "Agate", "crew-02": "Basalt", "crew-03": "Cobble", "crew-04": "Dusty", "crew-05": "Ember", "crew-06": "Flint", "crew-07": "Gravel", "crew-08": "Hazel", "crew-09": "Ingot", "crew-10": "Jasper", "crew-11": "Kettle", "crew-12": "Loam", "crew-13": "Marble", "crew-14": "Nugget", "crew-15": "Onyx", "crew-16": "Pebble", "crew-17": "Quartz", "crew-18": "Rusty", "crew-19": "Slate", "crew-20": "Tinder"}
# The squad members and the role each carries inside it; warriors only.
squads = {"crew-18": "vanguard", "crew-19": "striker", "crew-20": "ranger"}
own_claim = {"crew-01", "crew-02", "crew-03"}
roles = {"miner", "chopper", "hauler", "shaft"}

deps = {d["metadata"]["name"]: d for d in crew("Deployment")}
assert sorted(deps) == sorted(want), f"deployments: {sorted(deps)}"
assert sorted(d["metadata"]["name"] for d in crew("Service")) == sorted(want)
# The namespace caps claims at 20, so units past the third share one.
assert sorted(d["metadata"]["name"] for d in crew("PersistentVolumeClaim")) == sorted(own_claim | {"crew-shared"})

def env(dep):
    c = dep["spec"]["template"]["spec"]["containers"][0]
    return {e["name"]: e for e in c["env"]}

chests = set()
for uid, name in want.items():
    dep = deps[uid]
    e = env(dep)
    assert e["MC_USERNAME"]["value"] == name, (uid, e["MC_USERNAME"])
    assert len(name) <= 16
    assert e["CREW_ID"]["value"] == uid, (uid, e["CREW_ID"])
    assert dep["spec"]["strategy"]["type"] == "Recreate", uid
    assert dep["spec"]["selector"]["matchLabels"] == {"app": uid}, uid
    assert dep["spec"]["template"]["metadata"]["labels"]["app"] == uid, uid
    claim = dep["spec"]["template"]["spec"]["volumes"][0]["persistentVolumeClaim"]["claimName"]
    assert claim == (uid if uid in own_claim else "crew-shared"), (uid, claim)
    assert e["CAMERA_ATLAS_DIR"]["value"] == "/data/atlas", uid
    if uid not in own_claim:
        assert e["AUTH_CACHE_DIR"]["value"] == f"/data/{uid}/auth", uid
    if uid in squads:
        # A warrior fights, it does not work: no idle plan on the pod, and the
        # squad env carries the in-squad role, not the yard role.
        assert "WORK_PLAN" not in e, (uid, "warriors must have no WORK_PLAN")
        assert e["CREW_ROLE"]["value"] == squads[uid], (uid, e["CREW_ROLE"])
        assert e["CREW_SQUAD"]["value"] == "alpha", (uid, e["CREW_SQUAD"])
    else:
        assert "CREW_ROLE" not in e and "CREW_SQUAD" not in e, uid
        plan = json.loads(e["WORK_PLAN"]["value"])
        assert 1 <= len(plan) <= 8, (uid, plan)
        mine = {json.dumps(c, sort_keys=True) for t in plan for c in [t.get("chest")] + [t.get("to")] + (t.get("from") or []) if c}
        assert not (mine & chests), f"{uid} shares a chest with another unit"
        chests |= mine
    assert int(e["JOIN_DELAY_S"]["value"] if "JOIN_DELAY_S" in e else 0) == (int(uid[5:]) - 1) * 6, uid
    ref = e["TASKS_TOKEN"]["valueFrom"]["secretKeyRef"]
    assert ref["name"] == "crew-tasks" and ref.get("optional") is True, (uid, ref)
    x, y, z = (int(v) for v in e["KIT_CHEST"]["value"].split(","))
    assert 1 <= int(e["KIT_FOOD"]["value"]) <= 64, (uid, e["KIT_FOOD"])

for svc in crew("Service"):
    assert svc["spec"]["selector"] == {"app": svc["metadata"]["name"]}

def milli(v):
    return int(v[:-1]) if v.endswith("m") else int(float(v) * 1000)

total = sum(milli(d["spec"]["template"]["spec"]["containers"][0]["resources"]["limits"]["cpu"])
            for d in deps.values())
# 20 units at 50m; the namespace sum is worked out in values.yaml.
assert total <= 1000, f"crew limits.cpu totals {total}m, want <= 1000m"
mem = sum(int(d["spec"]["template"]["spec"]["containers"][0]["resources"]["limits"]["memory"][:-2]) for d in deps.values())
assert mem <= 20 * 384, f"crew limits.memory totals {mem}Mi, want <= 7680Mi"
assert len(chests) >= len(want) - len(squads)
PY

# A unit's replicas can be overridden alone, including to 0.
helm template crew-lab "$chart" --namespace jdwillmsen-prd \
  -f "$chart/values.yaml" -f "$chart/values-prd.yaml" \
  --set crew.units[1].replicas=0 > "$work/scaled.yaml"
python3 - "$work/scaled.yaml" <<'PY' || fail "per-unit replicas override is wrong"
import sys, yaml
reps = {d["metadata"]["name"]: d["spec"]["replicas"]
        for d in yaml.safe_load_all(open(sys.argv[1]))
        if d and d.get("kind") == "Deployment" and d["metadata"]["labels"].get("app.kubernetes.io/component") == "crew"}
assert reps == {k: (0 if k == "crew-02" else 1) for k in {"crew-01": "Agate", "crew-02": "Basalt", "crew-03": "Cobble", "crew-04": "Dusty", "crew-05": "Ember", "crew-06": "Flint", "crew-07": "Gravel", "crew-08": "Hazel", "crew-09": "Ingot", "crew-10": "Jasper", "crew-11": "Kettle", "crew-12": "Loam", "crew-13": "Marble", "crew-14": "Nugget", "crew-15": "Onyx", "crew-16": "Pebble", "crew-17": "Quartz", "crew-18": "Rusty", "crew-19": "Slate", "crew-20": "Tinder"}}, reps
PY

echo "PASS: crew units render as expected"
