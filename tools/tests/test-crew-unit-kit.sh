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
for name in ('Pebble', 'Quartz'):
    assert f'name="{name}",hasitem' not in equip, name
    assert f'name="{name}",x=0' in equip, name

# The squad trades the yard kit for the combat one: diamond and a bow in the
# yard kit's slots, one line per piece to top it up, no iron anywhere and no
# bread. Nothing sends a warrior to its plot, so its yard and chest stay
# unbuilt somewhere else.
for name in ('Rusty', 'Slate', 'Tinder'):
    got = [l.strip() for l in equip.splitlines() if f'name="{name}",hasitem' in l]
    want = [f'execute as @a[name="{name}",hasitem={{item=diamond_sword,quantity=0}}] run replaceitem entity @s slot.hotbar 8 diamond_sword 1',
            f'execute as @a[name="{name}",hasitem={{item=bow,quantity=0}}] run replaceitem entity @s slot.hotbar 0 bow 1',
            f'execute as @a[name="{name}",hasitem={{item=arrow,quantity=0}}] run replaceitem entity @s slot.hotbar 1 arrow 64',
            f'execute as @a[name="{name}",hasitem={{item=golden_apple,quantity=0}}] run replaceitem entity @s slot.hotbar 7 golden_apple 16',
            f'execute as @a[name="{name}",hasitem={{item=shield,location=slot.weapon.offhand,quantity=0}}] run replaceitem entity @s slot.weapon.offhand 0 shield 1',
            f'execute as @a[name="{name}",hasitem={{item=diamond_helmet,location=slot.armor.head,quantity=0}}] run replaceitem entity @s slot.armor.head 0 diamond_helmet 1',
            f'execute as @a[name="{name}",hasitem={{item=diamond_chestplate,location=slot.armor.chest,quantity=0}}] run replaceitem entity @s slot.armor.chest 0 diamond_chestplate 1',
            f'execute as @a[name="{name}",hasitem={{item=diamond_leggings,location=slot.armor.legs,quantity=0}}] run replaceitem entity @s slot.armor.legs 0 diamond_leggings 1',
            f'execute as @a[name="{name}",hasitem={{item=diamond_boots,location=slot.armor.feet,quantity=0}}] run replaceitem entity @s slot.armor.feet 0 diamond_boots 1']
    assert sorted(got) == sorted(want), (name, sorted(got))
    assert f'name="{name}",x=0' not in equip, name
    assert f'name="{name}"' not in restock, name

# Yards are kept supplied: every working plot gets two chests, and a working
# unit is sent to its plot (17 units; the three warriors get neither).
assert restock.count("chest [] keep") == 34, restock.count("chest [] keep")
assert equip.count("run tp @s") == 17
# A miner's quarry is refilled row by row, skipping rows its unit is in or beside.
assert restock.count("unless entity @a[name=") == 30, restock.count("unless entity @a[name=")
assert "unit_kit/restock" in cm["tick.mcfunction"]

# The Dota kit ships byte-for-byte and the function loads it with its entities.
kit = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "crew-lab-unit-kit")["binaryData"]["dota_kit.mcstructure"]
assert base64.b64decode(kit) == open(sys.argv[2], "rb").read(), "rendered Dota kit differs from the generated one"
for kit in ("dota", "lightking"):
    fn = cm[kit + ".mcfunction"]
    assert f"structure load {kit}_kit ~ ~ ~ 0_degrees none true false" in fn
    assert "armoury" not in fn and "redstone_block" not in fn
    assert "\nscriptevent kits:arrange " + {"dota": "Dota's", "lightking": "Light King's"}[kit] + "\n" in fn
assert any(m["type"] == "script" and m["entry"] == "scripts/main.js" for m in manifest["modules"])
assert "kits:arrange" in cm["main.js"]
assert 'Dotablaze: "dota"' in cm["main.js"] and "function kits/${kit}" in cm["main.js"]
assert "armory" not in cm["tick.mcfunction"] and "armory_clean.mcfunction" not in cm
assert "kits:dog" in cm["main.js"] and "tame(" in cm["main.js"] and "setEquipment(WORN" in cm["main.js"]

sts = next(d for d in docs if d["kind"] == "StatefulSet")["spec"]["template"]["spec"]
init = next(c for c in sts["initContainers"] if c["name"] == "install-unit-kit")
assert pack_id in init["command"][2], "init container registers a different pack id"
assert "armoury" not in init["command"][2] and "armory_clean" not in init["command"][2]
assert "structures/lightking_kit.mcstructure" in init["command"][2] and "functions/kits/lightking.mcfunction" in init["command"][2]
assert "scriptevent kits:dog Cassie" in cm["lightking.mcfunction"] and "wolf_armor" in cm["main.js"]
assert "structures/dota_kit.mcstructure" in init["command"][2] and "functions/kits/dota.mcfunction" in init["command"][2]
assert "scripts/main.js" in init["command"][2]
assert any(v["name"] == "unit-kit" and v["configMap"]["name"] == "crew-lab-unit-kit" for v in sts["volumes"])
PY

echo "PASS: unit kit renders as expected"
