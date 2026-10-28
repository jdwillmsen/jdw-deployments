#!/usr/bin/env bash
# Renders the crew-lab chart and checks that every unit has a writable place
# for the camera's texture atlas. A unit on the ReadWriteMany claim gets no
# fsGroup ownership change from the storage driver, so without the init step
# its mkdir under /data is refused and the camera draws flat colours.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/crew-lab"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template crew-lab "$chart" --namespace jdwillmsen-prd \
  -f "$chart/values.yaml" -f "$chart/values-prd.yaml" > "$work/rendered.yaml"

python3 - "$work/rendered.yaml" <<'PY' || fail "a unit has no writable atlas directory"
import re, sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
units = [d for d in docs if d["kind"] == "Deployment" and re.fullmatch(r"crew-\d\d", d["metadata"]["name"])]
assert len(units) == 22, f"want 22 units, got {len(units)}"

claims = {d["metadata"]["name"]: d for d in docs if d["kind"] == "PersistentVolumeClaim"}
shared_dirs = set()
for u in units:
    name = u["metadata"]["name"]
    pod = u["spec"]["template"]["spec"]
    crew = next(c for c in pod["containers"] if c["name"] == "crew")
    env = {e["name"]: e.get("value") for e in crew["env"]}
    atlas = env.get("CAMERA_ATLAS_DIR")
    assert atlas and atlas.startswith("/data/"), f"{name}: atlas dir {atlas!r} is not on /data"
    claim = next(v for v in pod["volumes"] if v["name"] == "data")["persistentVolumeClaim"]["claimName"]
    assert claim in claims, f"{name}: claim {claim} is not rendered"
    modes = claims[claim]["spec"]["accessModes"]
    inits = pod.get("initContainers", [])
    if "ReadWriteMany" in modes:
        shared_dirs.add(atlas)
        assert len(inits) == 1, f"{name}: want the share-owner init, got {[i['name'] for i in inits]}"
        init = inits[0]
        sc = init["securityContext"]
        assert sc["runAsUser"] == 0 and sc["capabilities"] == {"drop": ["ALL"], "add": ["CHOWN"]}, f"{name}: init is over- or under-privileged"
        assert sc["allowPrivilegeEscalation"] is False and sc["readOnlyRootFilesystem"] is True, f"{name}: init can write or escalate"
        assert any(m["mountPath"] == "/data" for m in init["volumeMounts"]), f"{name}: init does not mount /data"
        assert "chown 1000:1000 /data" in " ".join(init["command"]), f"{name}: init does not chown the root"
        assert "memory" in init["resources"]["limits"] and "cpu" in init["resources"]["limits"], f"{name}: init has no limits"
        assert env.get("AUTH_CACHE_DIR") == f"/data/{name}/auth", f"{name}: token cache is not its own"
    else:
        assert not inits, f"{name}: an unshared unit needs no init"

assert len(shared_dirs) == 1, f"shared units must use one atlas dir, got {sorted(shared_dirs)}"
PY

echo "PASS: every crew unit has a writable shared atlas directory"
