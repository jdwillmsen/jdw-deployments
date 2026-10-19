#!/usr/bin/env bash
# Renders the crew-lab chart and checks the unit-kit behaviour pack: valid JSON,
# one gear block per crew unit, and the init container that installs it.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/crew-lab"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template crew-lab "$chart" --namespace jdwillmsen-prd \
  -f "$chart/values.yaml" -f "$chart/values-prd.yaml" > "$work/rendered.yaml"

python3 - "$work/rendered.yaml" <<'PY' || fail "the unit kit is not rendered as expected"
import sys, json, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cm = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "crew-lab-unit-kit")["data"]

manifest = json.loads(cm["manifest.json"])
json.loads(cm["tick.json"])
pack_id = manifest["header"]["uuid"]

equip = cm["equip.mcfunction"]
for name in ("Agate", "Basalt", "Cobble"):
    assert equip.count(f'name="{name}"') == 5, name

sts = next(d for d in docs if d["kind"] == "StatefulSet")["spec"]["template"]["spec"]
init = next(c for c in sts["initContainers"] if c["name"] == "install-unit-kit")
assert pack_id in init["command"][2], "init container registers a different pack id"
assert any(v["name"] == "unit-kit" and v["configMap"]["name"] == "crew-lab-unit-kit" for v in sts["volumes"])
PY

echo "PASS: unit kit renders as expected"
