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

for kit in dota lightking; do
  python3 "$here/tools/crew-lab-dota-kit.py" "$work/${kit}_kit.mcstructure" "$kit"
  cmp -s "$work/${kit}_kit.mcstructure" "$chart/files/${kit}_kit.mcstructure" \
    || fail "charts/crew-lab/files/${kit}_kit.mcstructure is stale: rerun tools/crew-lab-dota-kit.py"
  python3 "$here/tools/crew-lab-dota-kit.py" "$work/${kit}_armoury.mcstructure" "$kit" armoury
  cmp -s "$work/${kit}_armoury.mcstructure" "$chart/files/${kit}_armoury.mcstructure" \
    || fail "charts/crew-lab/files/${kit}_armoury.mcstructure is stale: rerun tools/crew-lab-dota-kit.py"
done

python3 - "$work/rendered.yaml" "$work/dota_kit.mcstructure" <<'PY' || fail "the unit kit is not rendered as expected"
import base64, sys, json, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cm = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "crew-lab-unit-kit")["data"]

restock = cm["restock.mcfunction"]
manifest = json.loads(cm["manifest.json"])
json.loads(cm["tick.json"])
pack_id = manifest["header"]["uuid"]

equip = cm["equip.mcfunction"]
for name in ('Agate', 'Basalt', 'Cobble', 'Dusty', 'Ember', 'Flint', 'Gravel', 'Hazel', 'Ingot', 'Jasper', 'Kettle', 'Loam', 'Marble', 'Nugget', 'Onyx'):
    assert all(equip.count(f'name="{name}",hasitem={{item=iron_{p}') == 1 for p in ('sword', 'helmet', 'chestplate', 'leggings', 'boots')), name

# Hard-mode units get no gear at all.
for name in ('Pebble', 'Quartz', 'Rusty', 'Slate', 'Tinder'):
    assert f'name="{name}",hasitem' not in equip, name
    assert f'name="{name}",x=0' in equip, name

# Yards are kept supplied: every plot gets two chests, and a unit is sent to its plot.
assert restock.count("chest [] keep") == 40, restock.count("chest [] keep")
assert equip.count("run tp @s") == 20
# A miner's quarry is refilled row by row, skipping rows its unit is in or beside.
assert restock.count("unless entity @a[name=") == 36, restock.count("unless entity @a[name=")
assert "unit_kit/restock" in cm["tick.mcfunction"]

# The Dota kit ships byte-for-byte and the function loads it with its entities.
kit = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "crew-lab-unit-kit")["binaryData"]["dota_kit.mcstructure"]
assert base64.b64decode(kit) == open(sys.argv[2], "rb").read(), "rendered Dota kit differs from the generated one"
for kit in ("dota", "lightking"):
    fn = cm[kit + ".mcfunction"]
    assert f"structure load {kit}_kit ~ ~ ~ 0_degrees none true false" in fn
    assert f"structure load {kit}_armoury ~-1 ~ ~-1 0_degrees none false true" in fn
    assert fn.count("redstone_block") == 4 and "armory_rig" in fn
    assert "\nscriptevent kits:arrange " + {"dota": "Dota's", "lightking": "Light King's"}[kit] + "\n" in fn
assert any(m["type"] == "script" and m["entry"] == "scripts/main.js" for m in manifest["modules"])
assert "kits:arrange" in cm["main.js"]
assert "armory_clean" in cm["tick.mcfunction"] and "kill @s" in cm["armory_clean.mcfunction"]

sts = next(d for d in docs if d["kind"] == "StatefulSet")["spec"]["template"]["spec"]
init = next(c for c in sts["initContainers"] if c["name"] == "install-unit-kit")
assert pack_id in init["command"][2], "init container registers a different pack id"
assert "structures/lightking_armoury.mcstructure" in init["command"][2] and "armory_clean" in init["command"][2]
assert "structures/lightking_kit.mcstructure" in init["command"][2] and "functions/kits/lightking.mcfunction" in init["command"][2]
assert "summon wolf Lumen" in cm["lightking.mcfunction"] and "slot.armor.body" in cm["lightking.mcfunction"]
assert "structures/dota_kit.mcstructure" in init["command"][2] and "functions/kits/dota.mcfunction" in init["command"][2]
assert "scripts/main.js" in init["command"][2]
assert any(v["name"] == "unit-kit" and v["configMap"]["name"] == "crew-lab-unit-kit" for v in sts["volumes"])
PY

echo "PASS: unit kit renders as expected"
