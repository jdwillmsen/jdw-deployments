#!/usr/bin/env bash
# The world guard (tools/world-guard): the checker's unit tests, that every chart
# running the guard carries exactly the tested source, and that the pod specs around
# it cannot become the thing that keeps a world offline.
#
# Why each rule, in one line apiece, because they are easy to "tidy" away:
#  - the guard is an init container that runs before the server: anything it waits on,
#    the server waits on. So no Secret, one mount, a pinned image that is already on
#    every node, and a script that exits 0 on anything it cannot decide.
#  - the YAML copy of the script is generated, not written, so the code the unit tests
#    ran is the code the pod runs.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

python3 -W error::ResourceWarning "$here/tools/world-guard/test_world_guard.py" >"$work/unit.log" 2>&1 \
  || { cat "$work/unit.log"; fail "the checker's unit tests fail"; }

python3 "$here/tools/world-guard/embed.py" --check >"$work/embed.log" 2>&1 \
  || { cat "$work/embed.log"; fail "a chart's embedded world guard differs from tools/world-guard/world_guard.py"; }
grep -q 'in sync' "$work/embed.log" || fail "no chart carries a world-guard block, so the sync check proved nothing"

# Both charts that run the guard are held to the same rules. The mode each is
# expected to be in is the one thing that differs, and it is spelled out here so
# that flipping a release to enforce (or back) is a deliberate edit of this file:
# the main server starts in warn and goes to enforce in a separate change; going
# back to warn after that, and enforce again after that, are the owner's call.
pg="$here/charts/proving-grounds"
helm template jdwillmsen-proving-grounds-prd "$pg" --namespace jdwillmsen-prd \
  -f "$pg/values.yaml" -f "$pg/values-prd.yaml" > "$work/pg.yaml"
helm template jdwillmsen-proving-grounds-prd "$pg" --namespace jdwillmsen-prd \
  -f "$pg/values.yaml" -f "$pg/values-prd.yaml" --set global.worldSync.enabled=false > "$work/pg-nosync.yaml"

fwb="$here/charts/minecraft-fwb"
fwb_values=(-f "$fwb/values.yaml" -f "$fwb/values-prd.yaml" -f "$fwb/values-console-bridge.yaml" -f "$fwb/values-map-pack.yaml")
helm template jdwillmsen-minecraft-fwb-prd "$fwb" --namespace jdwillmsen-prd "${fwb_values[@]}" > "$work/fwb.yaml"
helm template jdwillmsen-minecraft-fwb-prd "$fwb" --namespace jdwillmsen-prd "${fwb_values[@]}" \
  --set global.worldSync.enabled=true > "$work/fwb-sync.yaml"

check_chart() {
  python3 - "$here" "$@" <<'PY'
import sys, yaml

here, name, plain, synced, mode, sync_default = sys.argv[1:7]
src = open(f"{here}/tools/world-guard/world_guard.py").read()

def sts(path):
    docs = [d for d in yaml.safe_load_all(open(path)) if d]
    return next(d for d in docs if d["kind"] == "StatefulSet" and d["metadata"]["name"].endswith("-minecraft-bedrock"))["spec"]["template"]["spec"]

def no_secret_anywhere(container, where):
    text = yaml.safe_dump(container)
    for word in ("secretKeyRef", "envFrom", "secretName", "configMapKeyRef", "valueFrom"):
        assert word not in text, f"{name}: {where} references {word}: a name that cannot resolve holds the server in Init"

pod = sts(plain)
guard = pod["initContainers"][0]
assert guard["name"] == "world-guard", f"{name}: the guard must run before every other init step"
assert guard["command"] == ["python3", "-I", "-c"], guard["command"]
assert guard["args"] == [src], f"{name}: the embedded source is not tools/world-guard/world_guard.py"
import re
assert re.fullmatch(r"alpine/k8s:\d+\.\d+\.\d+", guard["image"]) and guard["imagePullPolicy"] == "IfNotPresent", guard["image"]
env = {e["name"]: e.get("value") for e in guard["env"]}
assert env["DATA_DIR"] == "/data" and env["RECHECK_SECONDS"] == "30", env
assert env["GUARD_MODE"] == mode, f"{name}: GUARD_MODE is {env['GUARD_MODE']!r}, this test expects {mode!r}"
srv = {e["name"]: e.get("value") for e in pod["containers"][0]["env"]}
assert env["LEVEL_NAME"] == srv["LEVEL_NAME"], f"{name}: the guard checks a different world from the one the server opens"
assert [m["name"] for m in guard["volumeMounts"]] == ["datadir"] and not guard["volumeMounts"][0].get("readOnly"), guard["volumeMounts"]
sc = guard["securityContext"]
assert sc["runAsUser"] == 1000 and sc["runAsGroup"] == 3000 and sc["runAsNonRoot"] is True, sc
assert sc["readOnlyRootFilesystem"] is True and sc["allowPrivilegeEscalation"] is False, sc
assert sc["capabilities"] == {"drop": ["ALL"]}, sc
assert not any(k.endswith("Probe") for k in guard) and "lifecycle" not in guard and "restartPolicy" not in guard, f"{name}: nothing may be able to fail the guard but the guard"
assert set(guard["resources"]) == {"requests", "limits"} and set(guard["resources"]["limits"]) == {"cpu", "memory"}, "the quota refuses a pod without limits"
no_secret_anywhere(guard, "world-guard")

def names(p): return [c["name"] for c in p["containers"]]
if sync_default == "on":
    assert "world-sync" in names(pod), f"{name}: world-sync should be on in the release's own values"
else:
    assert "world-sync" not in names(pod), f"{name}: world-sync must be off unless global.worldSync.enabled"

pod = sts(synced)
sync = next(c for c in pod["containers"] if c["name"] == "world-sync")
assert sync["image"] == pod["containers"][0]["image"], f"{name}: world-sync must run the server's own image (it ships sync)"
assert sync["command"][:2] == ["sh", "-c"] and "sync -f /data" in sync["command"][2] and "sleep 2" in sync["command"][2] and "trap 'exit 0' TERM" in sync["command"][2], sync["command"]
assert sync["volumeMounts"] == [{"name": "datadir", "mountPath": "/data", "readOnly": True}], sync["volumeMounts"]
assert sync["securityContext"]["readOnlyRootFilesystem"] is True and sync["securityContext"]["capabilities"] == {"drop": ["ALL"]}
assert "ports" not in sync, "the sidecar must not open a port"
assert set(sync["resources"]) == {"requests", "limits"}
no_secret_anywhere(sync, "world-sync")
PY
}

python3 - "$work/fwb.yaml" <<'PY' || fail "the restore scratch claim could be pruned"
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
claim = next(d for d in docs if d["kind"] == "PersistentVolumeClaim" and d["metadata"]["name"].endswith("-restore-scratch"))
assert claim["metadata"]["annotations"]["argocd.argoproj.io/sync-options"] == "Prune=false", claim["metadata"]
PY

check_chart proving-grounds "$work/pg-nosync.yaml" "$work/pg.yaml" enforce off \
  || fail "the proving-grounds guard or sidecar is not what the rules require"
check_chart minecraft-fwb "$work/fwb.yaml" "$work/fwb-sync.yaml" warn off \
  || fail "the main server's guard or sidecar is not what the rules require"

echo "PASS: world guard"
