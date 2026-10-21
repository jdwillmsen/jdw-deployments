#!/usr/bin/env bash
# Renders the crew-lab chart and checks the unit-kit behaviour pack: valid JSON,
# one gear block per crew unit, the Dota kit, and the init container that
# installs it.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/crew-lab"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template crew-lab "$chart" --namespace jdwillmsen-prd \
  -f "$chart/values.yaml" -f "$chart/values-prd.yaml" > "$work/rendered.yaml"

python3 "$here/tools/crew-lab-dota-kit.py" "$work/dota_kit.mcstructure"
cmp -s "$work/dota_kit.mcstructure" "$chart/files/dota_kit.mcstructure" \
  || fail "charts/crew-lab/files/dota_kit.mcstructure is stale: rerun tools/crew-lab-dota-kit.py"

python3 - "$work/rendered.yaml" "$work/dota_kit.mcstructure" <<'PY' || fail "the unit kit is not rendered as expected"
import base64, sys, json, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cm = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "crew-lab-unit-kit")["data"]

restock = cm["restock.mcfunction"]
manifest = json.loads(cm["manifest.json"])
json.loads(cm["tick.json"])
pack_id = manifest["header"]["uuid"]

equip = cm["equip.mcfunction"]
for name in ('Agate', 'Basalt', 'Cobble', 'Dusty', 'Ember', 'Flint', 'Gravel', 'Hazel', 'Ingot', 'Jasper', 'Kettle', 'Loam', 'Marble', 'Nugget', 'Onyx', 'Pebble', 'Quartz', 'Rusty', 'Slate', 'Tinder'):
    assert all(equip.count(f'name="{name}",hasitem={{item=iron_{p}') == 1 for p in ('sword', 'helmet', 'chestplate', 'leggings', 'boots')), name

# Yards are kept supplied: every plot gets two chests, and a unit is sent to its plot.
assert restock.count("chest [] keep") == 40, restock.count("chest [] keep")
assert equip.count("run tp @s") == 20
# A miner's quarry is refilled row by row, skipping rows its unit is in or beside.
assert restock.count("unless entity @a[name=") == 36, restock.count("unless entity @a[name=")
assert "unit_kit/restock" in cm["tick.mcfunction"]

# The Dota kit ships byte-for-byte and the function loads it with its entities.
kit = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "crew-lab-unit-kit")["binaryData"]["dota_kit.mcstructure"]
assert base64.b64decode(kit) == open(sys.argv[2], "rb").read(), "rendered Dota kit differs from the generated one"
assert cm["dota.mcfunction"].strip() == "structure load dota_kit ~ ~ ~ 0_degrees none true false"

sts = next(d for d in docs if d["kind"] == "StatefulSet")["spec"]["template"]["spec"]
init = next(c for c in sts["initContainers"] if c["name"] == "install-unit-kit")
assert pack_id in init["command"][2], "init container registers a different pack id"
assert "structures/dota_kit.mcstructure" in init["command"][2] and "functions/kits/dota.mcfunction" in init["command"][2]
assert any(v["name"] == "unit-kit" and v["configMap"]["name"] == "crew-lab-unit-kit" for v in sts["volumes"])
PY

echo "PASS: unit kit renders as expected"
