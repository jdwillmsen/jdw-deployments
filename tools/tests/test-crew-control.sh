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
import json, sys, yaml

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

assert [u["name"] for u in units] == ["Agate", "Basalt", "Cobble"], units
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

for u in ("crew-01", "crew-02", "crew-03"):
    ud = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == u)
    ue = {e["name"]: e for e in ud["spec"]["template"]["spec"]["containers"][0]["env"]}
    assert ue["CONTROL_URL"]["value"] == "http://crew-control:8080", u
    assert ue["CONTROL_TOKEN"]["valueFrom"]["secretKeyRef"] == {"name": "crew-work", "key": "token"}, u
assert c["livenessProbe"]["httpGet"]["path"] == "/healthz"
assert c["readinessProbe"]["httpGet"]["path"] == "/healthz"
assert c["image"] == "ghcr.io/jdwillmsen/minecraft-crew-control:1.2.0", c["image"]

cpu = c["resources"]["limits"]["cpu"]
milli = int(cpu[:-1]) if cpu.endswith("m") else int(float(cpu) * 1000)
assert milli <= 50, f"crew-control limits.cpu is {cpu}, want <= 50m"

svc = next(d for d in docs if d["kind"] == "Service" and d["metadata"]["name"] == "crew-control")
assert svc["spec"]["type"] == "ClusterIP"
assert svc["spec"]["selector"] == {"app": "crew-control"}
'

render > "$work/rendered.yaml"
python3 -c "$check" "$work/rendered.yaml" '["crew-01","crew-02","crew-03"]' \
  || fail "crew-control is not rendered as expected"

render --set 'crew.units[1].replicas=0' > "$work/scaled.yaml"
python3 -c "$check" "$work/scaled.yaml" '["crew-01","crew-03"]' skip \
  || fail "a stopped unit is still listed by crew-control"

render --set 'crew.units[0].replicas=0' --set 'crew.units[1].replicas=0' \
  --set 'crew.units[2].replicas=0' > "$work/empty.yaml"
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
    if d["kind"] == "Deployment" and d["metadata"]["name"].startswith("crew-0"):
        names = [e["name"] for e in d["spec"]["template"]["spec"]["containers"][0]["env"]]
        assert "CONTROL_URL" not in names and "CONTROL_TOKEN" not in names, "units still point at a missing crew-control"
assert not left, left
PY

echo "PASS: crew-control renders as expected"
