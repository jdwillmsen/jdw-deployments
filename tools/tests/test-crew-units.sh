#!/usr/bin/env bash
# Renders the crew-lab chart and checks the crew units: one Deployment, Service
# and PVC per unit, a shared task token, a kit chest to rearm from,
# and a total CPU limit that leaves the namespace quota headroom for the
# backup and recovery CronJobs.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/crew-lab"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template crew-lab "$chart" --namespace jdwillmsen-prd \
  -f "$chart/values.yaml" -f "$chart/values-prd.yaml" > "$work/rendered.yaml"

python3 - "$work/rendered.yaml" <<'PY' || fail "the crew units are not rendered as expected"
import sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]

def of(kind):
    return [d for d in docs if d.get("kind") == kind]

# The lab server's own StatefulSet/Service carry no crew label.
crew = lambda kind: [d for d in of(kind)
                     if d["metadata"].get("labels", {}).get("app.kubernetes.io/component") == "crew"]

want = {"crew-01": "Agate", "crew-02": "Basalt", "crew-03": "Cobble"}

deps = {d["metadata"]["name"]: d for d in crew("Deployment")}
assert sorted(deps) == sorted(want), f"deployments: {sorted(deps)}"
assert sorted(d["metadata"]["name"] for d in crew("Service")) == sorted(want)
assert sorted(d["metadata"]["name"] for d in crew("PersistentVolumeClaim")) == sorted(want)

def env(dep):
    c = dep["spec"]["template"]["spec"]["containers"][0]
    return {e["name"]: e for e in c["env"]}

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
    assert claim == uid, (uid, claim)
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
assert total <= 150, f"crew limits.cpu totals {total}m, want <= 150m"
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
assert reps == {"crew-01": 1, "crew-02": 0, "crew-03": 1}, reps
PY

echo "PASS: crew units render as expected"
