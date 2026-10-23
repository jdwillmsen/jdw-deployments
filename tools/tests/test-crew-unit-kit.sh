#!/usr/bin/env bash
# Renders the crew-lab chart and checks the unit-kit behaviour pack: valid JSON,
# one gear block per crew unit, the Dota and warrior kits, and the init
# container that installs them.
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

for role in vanguard striker ranger; do
  python3 "$here/tools/crew-lab-warrior-kit.py" "$work/warrior_${role}_kit.mcstructure" "$role"
  cmp -s "$work/warrior_${role}_kit.mcstructure" "$chart/files/warrior_${role}_kit.mcstructure" \
    || fail "charts/crew-lab/files/warrior_${role}_kit.mcstructure is stale: rerun tools/crew-lab-warrior-kit.py"
done

python3 - "$work/rendered.yaml" "$work/dota_kit.mcstructure" "$work" <<'PY' || fail "the unit kit is not rendered as expected"
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

# The squad trades the yard kit for the enchanted combat one. A warrior is
# tagged for a reload by one guarded line per missing piece (the hasitem
# checks that keep an enchanted piece from ever being replaced by a plain
# one), then runs its role's function. Nothing hands out plain gear, nothing
# sends a warrior to its plot, and its yard and chest stay unbuilt.
common = ['diamond_helmet,location=slot.armor.head', 'diamond_chestplate,location=slot.armor.chest',
          'diamond_leggings,location=slot.armor.legs', 'diamond_boots,location=slot.armor.feet',
          'diamond_sword', 'golden_apple']
pieces = {'vanguard': common + ['shield,location=slot.weapon.offhand'],
          'striker': common + ['totem_of_undying,location=slot.weapon.offhand'],
          'ranger': common + ['totem_of_undying,location=slot.weapon.offhand', 'bow', 'arrow']}
for name, role in (('Rusty', 'vanguard'), ('Slate', 'striker'), ('Tinder', 'ranger')):
    got = [l.strip() for l in equip.splitlines() if f'name="{name}"' in l]
    want = [f'scoreboard players add @a[name="{name}"] kitwait 0',
            f'scoreboard players remove @a[name="{name}",scores={{kitwait=1..}}] kitwait 1']
    want += [f'execute as @a[name="{name}",scores={{kitwait=..0}},hasitem={{item={p},quantity=0}}] run tag @s add kitneed' for p in pieces[role]]
    want += [f'execute as @a[name="{name}",tag=kitneed] at @s run function kits/warrior_{role}']
    assert got == want, (name, got)
    assert f'name="{name}",x=0' not in equip, name
    assert f'name="{name}"' not in restock, name
for plain in ("replaceitem entity @s slot.armor.head 0 diamond", "run replaceitem entity @s slot.hotbar 8 diamond_sword",
              "replaceitem entity @s slot.weapon.offhand 0 shield"):
    assert plain not in equip, plain
assert "objectives add kitwait" in cm["init.mcfunction"]

# Yards are kept supplied: every working plot gets two chests, and a working
# unit is sent to its plot (17 units; the three warriors get neither).
assert restock.count("chest [] keep") == 34, restock.count("chest [] keep")
assert equip.count("run tp @s") == 17
# A miner's quarry is refilled row by row, skipping rows its unit is in or beside.
assert restock.count("unless entity @a[name=") == 30, restock.count("unless entity @a[name=")
assert "unit_kit/restock" in cm["tick.mcfunction"]

# The Dota kit ships byte-for-byte and the function loads it with its entities.
docs_kit = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "crew-lab-unit-kit")["binaryData"]
kit = docs_kit["dota_kit.mcstructure"]
assert base64.b64decode(kit) == open(sys.argv[2], "rb").read(), "rendered Dota kit differs from the generated one"
for kit in ("dota", "lightking"):
    fn = cm[kit + ".mcfunction"]
    assert f"structure load {kit}_kit ~ ~ ~ 0_degrees none true false" in fn
    assert "armoury" not in fn and "redstone_block" not in fn
    assert "\nscriptevent kits:arrange " + {"dota": "Dota's", "lightking": "Light King's"}[kit] + "\n" in fn

# Little-endian NBT, just enough to read an item list back out of a structure.
import struct
def nbt(buf):
    pos = 0
    def take(fmt):
        nonlocal pos
        v = struct.unpack_from("<" + fmt, buf, pos); pos += struct.calcsize("<" + fmt)
        return v[0]
    def string():
        nonlocal pos
        n = take("H"); v = buf[pos:pos + n].decode(); pos += n
        return v
    def payload(kind):
        if kind == 1: return take("b")
        if kind == 2: return take("h")
        if kind == 3: return take("i")
        if kind == 4: return take("q")
        if kind == 5: return take("f")
        if kind == 8: return string()
        if kind == 9:
            elem, n = take("b"), take("i")
            return [payload(elem) for _ in range(n)]
        out = {}
        while True:
            k = take("b")
            if k == 0: return out
            key = string()
            out[key] = payload(k)
    assert take("b") == 10
    string()
    return payload(10)

ENCH = {0: "protection", 9: "sharpness", 17: "unbreaking", 19: "power"}
def warrior_kit(role):
    root = nbt(open(f"{sys.argv[3]}/warrior_{role}_kit.mcstructure", "rb").read())
    out = {}
    for e in root["structure"]["entities"]:
        it = e["Item"]
        assert it["Name"] not in out, (role, "duplicate", it["Name"])
        out[it["Name"].removeprefix("minecraft:")] = (it["Count"], sorted((ENCH[x["id"]], x["lvl"]) for x in it.get("tag", {}).get("ench", [])))
    return out

armor = [(p, 1, [("protection", 4), ("unbreaking", 3)]) for p in ("diamond_helmet", "diamond_chestplate", "diamond_leggings", "diamond_boots")]
sword = ("diamond_sword", 1, [("sharpness", 5), ("unbreaking", 3)])
apples = ("golden_apple", 16, [])
offhand = {"vanguard": ("shield", 1, [("unbreaking", 3)]),
           "striker": ("totem_of_undying", 1, []), "ranger": ("totem_of_undying", 1, [])}
bow = [("bow", 1, [("power", 5), ("unbreaking", 3)]), ("arrow", 64, [])]
for role in ("vanguard", "striker", "ranger"):
    want = {n: (c, sorted(e)) for n, c, e in armor + [sword, apples, offhand[role]] + (bow if role == "ranger" else [])}
    assert warrior_kit(role) == want, (role, warrior_kit(role))

for role in ("vanguard", "striker", "ranger"):
    fn = cm[f"warrior_{role}.mcfunction"]
    assert fn.splitlines() == ["tag @s remove kitneed", "scoreboard players set @s kitwait 5", "clear @s",
                               f"structure load warrior_{role}_kit ~ ~ ~ 0_degrees none true false", "scriptevent kits:warrior"], fn
    assert base64.b64decode(docs_kit[f"warrior_{role}_kit.mcstructure"]) == open(f"{sys.argv[3]}/warrior_{role}_kit.mcstructure", "rb").read(), role
assert "kits:warrior" in cm["main.js"] and "function equipWarrior" in cm["main.js"]
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
for part in ("/kit/warrior_$r.mcfunction", "functions/kits/warrior_$r.mcfunction", "/kit/warrior_${r}_kit.mcstructure", "structures/warrior_${r}_kit.mcstructure", "for r in vanguard striker ranger"):
    assert part in init["command"][2], part
# The pack's structures load only at server start, so the revision must have moved.
rev = next(e["value"] for e in init["env"] if e["name"] == "UNIT_KIT_REV")
assert int(rev) >= 13, rev
assert any(v["name"] == "unit-kit" and v["configMap"]["name"] == "crew-lab-unit-kit" for v in sts["volumes"])
PY

echo "PASS: unit kit renders as expected"
