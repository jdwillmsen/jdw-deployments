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

python3 "$here/tools/crew-lab-kits.py" "$work/kits.tar.gz" "$work/KITS.md"
cmp -s "$work/kits.tar.gz" "$chart/files/kits.tar.gz" \
  || fail "charts/crew-lab/files/kits.tar.gz is stale: rerun tools/crew-lab-kits.py"
cmp -s "$work/KITS.md" "$chart/KITS.md" || fail "charts/crew-lab/KITS.md is stale: rerun tools/crew-lab-kits.py"

want_rev="$(python3 "$here/tools/crew-lab-kit-rev.py")"
grep -qF "value: \"$want_rev\"" "$chart/values.yaml" \
  || fail "UNIT_KIT_REV is stale: run tools/crew-lab-kit-rev.py --write (it should be $want_rev)"

python3 - "$work/rendered.yaml" "$work/dota_kit.mcstructure" "$work/kits.tar.gz" <<'PY' || fail "the unit kit is not rendered as expected"
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

# The squad trades the yard kit for a catalog kit, handed out whole whenever the
# unit has no netherite chestplate anywhere (join, death, restart), plus a
# top-up of golden apples. No plain diamond or iron line is left, nothing sends
# a warrior to its plot, and its yard and chest stay unbuilt.
squad_kit = {"Rusty": "vanguard", "Slate": "duelist", "Tinder": "ranger"}
WORN = "{item=netherite_chestplate,location=slot.armor.chest,quantity=0}"
for name, role in squad_kit.items():
    got = [l.strip() for l in equip.splitlines() if f'name="{name}"' in l]
    sel = f'@a[name="{name}",scores={{kitwait=..0}},hasitem=['
    nowhere = sel + '{item=netherite_chestplate,quantity=0},' + WORN + ']]'
    carried = sel + '{item=netherite_chestplate,quantity=1..},' + WORN + ']]'
    want = [f'scoreboard players add @a[name="{name}"] kitwait 0',
            f'scoreboard players remove @a[name="{name}",scores={{kitwait=1..}}] kitwait 1',
            f'execute as {nowhere} at @s run function kits/{role}/t5',
            f'execute as {nowhere} run scoreboard players set @s kitwait 8',
            f'execute as {carried} run scriptevent kits:arrange Legendary {role.title()}',
            f'execute as {carried} run scoreboard players set @s kitwait 4',
            f'execute as @a[name="{name}",scores={{kitwait=..0}},hasitem={{item=golden_apple,quantity=0}}] run give @s golden_apple 16',
            f'execute as @a[name="{name}",scores={{kitwait=..0}},hasitem={{item=golden_apple,quantity=0}}] run scoreboard players set @s kitwait 8']
    assert got == want, (name, got)
    assert f'name="{name}"' not in restock, name
# Every hand-out is gated on the cooldown, so a slow pickup or a full inventory
# cannot hand out a second kit or loop the apples.
assert "objectives add kitwait" in cm["init.mcfunction"]
for l in equip.splitlines():
    if any(f'name="{n}"' in l for n in squad_kit) and ("function kits/" in l or "give @s" in l or "scriptevent" in l):
        assert "kitwait=..0" in l, l
assert "diamond_" not in equip and "slot.weapon.offhand" not in equip

# Yards are kept supplied: every working plot gets two chests, and a working
# unit is sent to its plot (17 units; the three warriors get neither).
assert restock.count("chest [] keep") == 34, restock.count("chest [] keep")
assert equip.count("run tp @s") == 17
# A miner's quarry is refilled row by row, skipping rows its unit is in or beside.
assert restock.count("unless entity @a[name=") == 30, restock.count("unless entity @a[name=")
assert "unit_kit/restock" in cm["tick.mcfunction"]

# A dead unit keeps its kit: the world rule is set once, ever, and then left to
# whoever changes it by hand.
tick = [l.strip() for l in cm["tick.mcfunction"].splitlines()]
guard = ["scoreboard players add rules unitkit 0",
         "execute if score rules unitkit matches 0 run gamerule keepinventory true",
         "scoreboard players set rules unitkit 1"]
at = tick.index(guard[0])
assert tick[at:at + 3] == guard, tick
assert tick.count("scoreboard players set rules unitkit 1") == 1 and sum("keepinventory" in l for l in tick) == 1

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
assert "tar -xzf /kit/kits.tar.gz" in init["command"][2]

# The catalog ships whole, every kit function finishes and tags its kit, and
# every roll covers its range exactly.
import io, re, tarfile
binary = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "crew-lab-unit-kit")["binaryData"]
assert base64.b64decode(binary["kits.tar.gz"]) == open(sys.argv[3], "rb").read(), "rendered kit catalog differs"
tar = tarfile.open(sys.argv[3])
names = set(tar.getnames())
assert len([n for n in names if n.startswith("structures/kit_")]) == 72
assert len([n for n in names if n.startswith("structures/mob_")]) == 42
for n in names:
    body = tar.extractfile(n).read()
    m = re.fullmatch(r"functions/kits/(\w+)/t(\d)\.mcfunction", n)
    if m:
        assert f"structures/kit_{m[1]}_t{m[2]}.mcstructure" in names and b"scriptevent kits:arrange" in body and b"tag @s add kitted" in body, n
    m = re.fullmatch(r"functions/mobs/(\w+)/t(\d)\.mcfunction", n)
    if m:
        assert f"structures/mob_{m[1]}_t{m[2]}.mcstructure" in names, n
    if n.endswith(("/roll.mcfunction", "/elite.mcfunction", "/random.mcfunction")):
        lines = body.decode().splitlines()
        top = int(lines[0].split()[-1])
        hit = sorted(int(x) for l in lines[1:] for x in re.search(r"matches (\S+)", l)[1].split(".."))
        assert hit[0] == 1 and hit[-1] == top, n
        for l in lines[1:]:
            assert l.split("run function ")[1] + ".mcfunction" in {x[len("functions/"):] for x in names}, l
assert "scoreboard objectives add kitroll dummy" in cm["init.mcfunction"]
# A kitted unit's gear is left alone, and its supplies never overwrite a slot.
for line in equip.splitlines():
    if "run replaceitem" in line:
        assert "tag=!kitted]" in line, line
    if "tag=kitted]" in line:
        assert "run give @s " in line and any(f"item={x}," in line for x in ("bread", "cobblestone")), line

assert 0 < equip.count("tag=kitted] run give @s bread") == equip.count("tag=!kitted] run replaceitem entity @s slot.hotbar 7 bread")
# Every kit function the equip tick calls ships in the catalog.
for fn in re.findall(r"run function (kits/\w+/t\d)", equip):
    assert f"functions/{fn}.mcfunction" in names, fn
assert len(re.findall(r"run function kits/", equip)) == 3
assert "MOB_GEAR" in cm["main.js"] and "EquipmentSlot.Head" in cm["main.js"]

assert any(v["name"] == "unit-kit" and v["configMap"]["name"] == "crew-lab-unit-kit" for v in sts["volumes"])
PY

# A squadRole outside the three the pack has kits for fails the render, instead
# of calling a function that does not exist.
for role in healer ""; do
  if helm template crew-lab "$chart" --namespace jdwillmsen-prd -f "$chart/values.yaml" \
      -f "$chart/values-prd.yaml" --set "crew.units[17].squadRole=$role" > "$work/bad.yaml" 2> "$work/bad.err"; then
    fail "squadRole '$role' rendered"
  fi
  grep -q "squadRole" "$work/bad.err" || fail "squadRole '$role' failed without naming squadRole: $(cat "$work/bad.err")"
done

# The stage-0 mob add-on: both packs ship in the ConfigMap, and the UUIDs the
# init container registers are the ones in their manifests.
python3 - "$work/rendered.yaml" <<'PY' || fail "the stage-0 mob add-on is not rendered as expected"
import base64, io, json, sys, tarfile, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cm = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "crew-lab-unit-kit")
tar = tarfile.open(fileobj=io.BytesIO(base64.b64decode(cm["binaryData"]["lab-mods-stage0.tar.gz"])))
script = next(c for d in docs if d["kind"] == "StatefulSet"
              for c in d["spec"]["template"]["spec"]["initContainers"] if c["name"] == "install-unit-kit")["command"][-1]
for pack in ("behavior_pack", "resource_pack"):
    header = json.load(tar.extractfile(f"{pack}/manifest.json"))["header"]
    assert header["uuid"] in script, pack
    assert f'version: {json.dumps(header["version"])}' in script, pack
PY

echo "PASS: unit kit renders as expected"
