#!/usr/bin/env python3
"""Builds the crew lab's kit catalog: every role kit for players and crew units
in six tiers, every mob kit, and the functions that hand them out or roll one
at random. Writes charts/crew-lab/files/kits.tar.gz (unpacked into the
unit-kit pack by the init container) and charts/crew-lab/KITS.md.

Usage: tools/crew-lab-kits.py [tarball-path [catalog-path]]
"""
import gzip
import importlib.util
import io
import math
import os
import sys
import tarfile

# Loaded by path (its name is not a module name); keep the cache out of tools/.
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location(
    "nbt", os.path.join(os.path.dirname(os.path.abspath(__file__)), "crew-lab-dota-kit.py"))
nbt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(nbt)
byte, short, int_, long_, float_, list_, tag = nbt.byte, nbt.short, nbt.int_, nbt.long_, nbt.float_, nbt.list_, nbt.tag
COMPOUND, FLOAT, INT, LIST, STRING = nbt.COMPOUND, nbt.FLOAT, nbt.INT, nbt.LIST, nbt.STRING

ENCHANT = dict(nbt.ENCHANT, fire_protection=1, blast_protection=3, projectile_protection=4,
               smite=10, riptide=30, piercing=34, breach=40)

# Weights are percentages of a roll; an elite roll draws only from 4-6.
TIERS = {
    1: dict(name="Common", colour="§f", armour="leather", metal="wooden", weight=30, elite=0),
    2: dict(name="Uncommon", colour="§a", armour="copper", metal="copper", weight=25, elite=0),
    3: dict(name="Rare", colour="§9", armour="iron", metal="iron", weight=20, elite=0),
    4: dict(name="Epic", colour="§d", armour="diamond", metal="diamond", weight=13, elite=50),
    5: dict(name="Legendary", colour="§6§l", armour="netherite", metal="netherite", weight=8, elite=35),
    6: dict(name="Mythic", colour="§c§l", armour="netherite", metal="netherite", weight=4, elite=15),
}
# A trim on armour of its own material does not show, hence the mix.
TRIM_MATERIAL = {3: "copper", 4: "amethyst", 5: "diamond", 6: "gold"}


def level(top, tier, primary):
    """The level an enchantment of max `top` gets at `tier`; 0 leaves it off.
    Tier 2 carries only the role's signature enchantments, at level 1."""
    return {1: 0, 2: 1 if primary else 0, 3: math.ceil(top / 2), 4: max(1, top - 1)}.get(tier, top)


# (enchantment, max level, signature)
def E(name, top, primary=False):
    return (name, top, primary)


HELMET = [E("protection", 4, True), E("respiration", 3), E("aqua_affinity", 1)]
CHEST = [E("protection", 4, True)]
LEGS = [E("protection", 4, True), E("swift_sneak", 3)]
BOOTS = [E("protection", 4, True), E("feather_falling", 4), E("depth_strider", 3)]
SWORD = [E("sharpness", 5, True), E("looting", 3), E("knockback", 2)]

# Each role: armour enchantments by piece, the items (kind, title, enchantments),
# what a kit adds beside the tier's food, a leather colour, a trim pattern and,
# for roles with a shield, its banner. "metal" kinds take the tier's metal.
ROLES = {
    "vanguard": dict(
        title="Vanguard", lore="Holds the line", colour=0x3B5BA5, trim="ward",
        armour=dict(chest=CHEST + [E("thorns", 3)], legs=LEGS + [E("thorns", 3)]),
        items=[("metal:sword", "Sword", SWORD), ("shield", "Shield", [])],
        banner=dict(Base=4, Patterns=[("sc", 15), ("bo", 15)]),
    ),
    "duelist": dict(
        title="Duelist", lore="First blood, every time", colour=0xB02E26, trim="sentry",
        items=[("metal:sword", "Sword", [E("sharpness", 5, True), E("fire_aspect", 2, True), E("looting", 3), E("knockback", 2)])],
        extras=[("golden_apple", 4, 4)],
    ),
    "berserker": dict(
        title="Berserker", lore="Splits shields and skulls", colour=0x835432, trim="rib",
        items=[("metal:axe", "Axe", [E("sharpness", 5, True), E("efficiency", 5)])],
        extras=[("golden_apple", 4, 4)],
    ),
    "ranger": dict(
        title="Ranger", lore="Never misses twice", colour=0x5E7C16, trim="wild",
        armour=dict(chest=[E("projectile_protection", 4, True)]),
        items=[("bow", "Bow", [E("power", 5, True), E("punch", 2), E("flame", 1), E("infinity", 1)]),
               ("metal:sword", "Sword", [E("sharpness", 5)])],
        extras=[("arrow", 64, 2)],
    ),
    "arbalist": dict(
        title="Arbalist", lore="Bolts through armour", colour=0x474F52, trim="vex",
        items=[("crossbow", "Crossbow", [E("quick_charge", 3, True), E("piercing", 4, True)]),
               ("crossbow", "Scatter Crossbow", [E("quick_charge", 3), E("multishot", 1, True)]),
               ("metal:sword", "Sword", [E("sharpness", 5)])],
        extras=[("arrow", 64, 2), ("firework_rocket", 16, 5)],
    ),
    "skybreaker": dict(
        title="Skybreaker", lore="What goes up comes down hard", colour=0x8932B8, trim="flow",
        items=[("mace", "Mace", [E("density", 5, True), E("wind_burst", 3, True), E("fire_aspect", 2)]),
               ("mace", "Breaker Mace", [E("breach", 4, True), E("wind_burst", 3)])],
        extras=[("wind_charge", 32, 2)],
    ),
    "lancer": dict(
        title="Lancer", lore="Reach is everything", colour=0xF9801D, trim="spire",
        items=[("metal:spear", "Spear", [E("sharpness", 5, True), E("lunge", 3, True), E("knockback", 2), E("looting", 3)]),
               ("shield", "Shield", [])],
        banner=dict(Base=1, Patterns=[("cr", 14), ("bo", 0)]),
    ),
    "tidecaller": dict(
        title="Tidecaller", lore="The sea answers", colour=0x169C9C, trim="tide",
        armour=dict(helmet=[E("protection", 4, True), E("respiration", 3, True), E("aqua_affinity", 1, True)],
                    boots=[E("protection", 4, True), E("depth_strider", 3, True), E("feather_falling", 4)]),
        items=[("trident", "Trident", [E("impaling", 5, True), E("loyalty", 3, True), E("channeling", 1)]),
               ("trident", "Riptide Trident", [E("impaling", 5), E("riptide", 3, True)])],
    ),
    "scout": dict(
        title="Scout", lore="Gone before you look", colour=0xFED83D, trim="wayfinder",
        armour=dict(legs=[E("protection", 4), E("swift_sneak", 3, True)],
                    boots=[E("protection", 4), E("feather_falling", 4, True), E("soul_speed", 3), E("depth_strider", 3)]),
        items=[("metal:sword", "Sword", [E("sharpness", 5, True), E("knockback", 2)]),
               ("bow", "Bow", [E("power", 5, True), E("infinity", 1)])],
        extras=[("arrow", 32, 1), ("elytra", 1, 5), ("firework_rocket", 64, 5)],
    ),
    "miner": dict(
        title="Miner", lore="Deep is where the good stuff is", colour=0x9D9D97, trim="shaper",
        items=[("metal:pickaxe", "Fortune Pickaxe", [E("efficiency", 5, True), E("fortune", 3, True)]),
               ("metal:pickaxe", "Silk Pickaxe", [E("efficiency", 5, True), E("silk_touch", 1)]),
               ("metal:shovel", "Shovel", [E("efficiency", 5, True), E("silk_touch", 1)]),
               ("metal:sword", "Sword", [E("sharpness", 5)])],
        extras=[("torch", 64, 1)],
    ),
    "homesteader": dict(
        title="Homesteader", lore="Fields, forests and full larders", colour=0x80C71F, trim="host",
        items=[("metal:axe", "Axe", [E("efficiency", 5, True), E("silk_touch", 1)]),
               ("metal:hoe", "Hoe", [E("efficiency", 5), E("fortune", 3, True)]),
               ("shears", "Shears", [E("efficiency", 5, True)]),
               ("fishing_rod", "Fishing Rod", [E("luck_of_the_sea", 3, True), E("lure", 3, True)])],
        extras=[("bone_meal", 32, 1)],
    ),
    "netherraider": dict(
        title="Nether Raider", lore="Walks through fire", colour=0xC74A1E, trim="snout",
        armour=dict(helmet=[E("fire_protection", 4, True)], chest=[E("fire_protection", 4, True)],
                    legs=[E("fire_protection", 4, True)],
                    boots=[E("fire_protection", 4, True), E("soul_speed", 3, True), E("feather_falling", 4)]),
        items=[("metal:sword", "Sword", [E("sharpness", 5, True), E("looting", 3)]),
               ("bow", "Bow", [E("power", 5, True), E("infinity", 1)])],
        # Piglins leave a player in any gold armour alone.
        extras=[("arrow", 32, 1), ("golden_helmet", 1, 1), ("flint_and_steel", 1, 1)],
    ),
}

# Food and the rest every kit of a tier carries: (item, count).
TIER_EXTRAS = {
    1: [("bread", 8)],
    2: [("bread", 16)],
    3: [("cooked_beef", 16)],
    4: [("cooked_beef", 32), ("golden_apple", 2)],
    5: [("golden_carrot", 32), ("golden_apple", 8), ("totem_of_undying", 1)],
    6: [("golden_carrot", 64), ("golden_apple", 16), ("enchanted_golden_apple", 4), ("totem_of_undying", 2)],
}

# Mobs that wear armour and hold weapons, each dressed as a role. Their gear
# carries MOB_GEAR, which the pack's script uses to delete it when it drops.
MOBS = {
    "zombie": "vanguard",
    "husk": "berserker",
    "drowned": "tidecaller",
    "skeleton": "ranger",
    "stray": "ranger",
    "wither_skeleton": "duelist",
    "piglin": "arbalist",
}
MOB_GEAR = "§r§8Mob gear"
PIECES = [("helmet", "Helmet"), ("chestplate", "Chestplate"), ("leggings", "Leggings"), ("boots", "Boots")]
SLOT_ENCH = {"helmet": HELMET, "chestplate": CHEST, "leggings": LEGS, "boots": BOOTS}
ROLE_SLOT = {"helmet": "helmet", "chestplate": "chest", "leggings": "legs", "boots": "boots"}


def stack(name, count=1, **t):
    out = {"Name": "minecraft:" + name, "Count": byte(count), "Damage": short(0), "WasPickedUp": byte(0)}
    if t:
        out["tag"] = t
    return out


def enchants(spec, tier):
    out = [(e, level(top, tier, primary)) for e, top, primary in spec]
    if tier >= 3:
        out.append(("unbreaking", level(3, tier, False)))
    # Infinity and Mending exclude each other.
    if tier >= 5 and not any(e == "infinity" for e, _, _ in spec):
        out.append(("mending", 1))
    return list_(COMPOUND, [{"id": short(ENCHANT[e]), "lvl": short(lv)} for e, lv in out if lv])


def label(tier, role, title):
    t = TIERS[tier]
    name = f"{t['colour']}{t['name']} {ROLES[role]['title']} {title}"
    return f"§r§e§k!!§r {name} §r§e§k!!§r" if tier == 6 else name


def gear(role, tier, mob=False):
    """The role's gear at a tier: (armour pieces, held items)."""
    r, t = ROLES[role], TIERS[tier]
    lore = [MOB_GEAR] if mob else [f"§r§7§o{r['lore']}", f"§r§8Tier {tier} · {t['name']}"]

    def named(title):
        return {"Name": label(tier, role, title), "Lore": list_(STRING, lore)} if not mob else {"Lore": list_(STRING, lore)}

    armour = []
    for piece, title in PIECES:
        extra = {}
        if t["armour"] == "leather":
            extra["customColor"] = int_(r["colour"] | -0x1000000)
        if tier in TRIM_MATERIAL:
            extra["Trim"] = {"Material": TRIM_MATERIAL[tier], "Pattern": r["trim"]}
        spec = r.get("armour", {}).get(ROLE_SLOT[piece], SLOT_ENCH[piece])
        armour.append((title, stack(f"{t['armour']}_{piece}", ench=enchants(spec, tier), display=named(title), **extra)))

    held = []
    for kind, title, spec in r["items"]:
        name = f"{t['metal']}_{kind[6:]}" if kind.startswith("metal:") else kind
        extra = {}
        if kind == "shield" and "banner" in r and tier >= 4:
            b = r["banner"]
            extra = {"Base": int_(b["Base"]), "Type": int_(0),
                     "Patterns": list_(COMPOUND, [{"Pattern": p, "Color": int_(c)} for p, c in b["Patterns"]])}
        held.append((title, stack(name, ench=enchants(spec, tier), display=named(title), **extra)))
    return armour, held


def kit_items(role, tier):
    armour, held = gear(role, tier)
    items = [s for _, s in armour] + [s for _, s in held]
    for name, count, from_tier in ROLES[role].get("extras", []):
        if tier >= from_tier:
            if name == "elytra":
                items.append(stack(name, ench=enchants([], tier), display={"Name": label(tier, role, "Elytra")}))
            else:
                items.append(stack(name, count))
    items += [stack(name, count) for name, count in TIER_EXTRAS[tier]]
    return items


def structure(entities):
    root = {
        "format_version": int_(1),
        "size": list_(INT, [int_(1)] * 3),
        "structure_world_origin": list_(INT, [int_(0)] * 3),
        "structure": {
            "block_indices": list_(LIST, [list_(INT, [int_(-1)]), list_(INT, [int_(-1)])]),
            "entities": list_(COMPOUND, entities),
            "palette": {"default": {"block_palette": list_(COMPOUND, []), "block_position_data": {}}},
        },
    }
    return nbt.struct.pack("<bH", COMPOUND, 0) + nbt.payload(tag(root))


def placed(identifier, uid, **rest):
    return {
        "identifier": "minecraft:" + identifier,
        "Pos": list_(FLOAT, [float_(0.5), float_(0.0), float_(0.5)]),
        "Motion": list_(FLOAT, [float_(0.0)] * 3),
        "Rotation": list_(FLOAT, [float_(0.0)] * 2),
        # The server gives every loaded entity a fresh id; these only need to
        # differ within one structure.
        "UniqueID": long_(uid),
        **rest,
    }


def kit_structure(role, tier):
    return structure([placed("item", -1 - n, Item=it) for n, it in enumerate(kit_items(role, tier))])


EMPTY = {"Name": "", "Count": byte(0), "Damage": short(0), "WasPickedUp": byte(0)}


def mob_structure(mob, tier):
    role = MOBS[mob]
    armour, held = gear(role, tier, mob=True)
    main = held[0][1]
    off = next((s for title, s in held if title == "Shield"), EMPTY)
    t = TIERS[tier]
    extra = {}
    if tier >= 4:
        extra = {"CustomName": f"{t['colour']}{t['name']} {mob.replace('_', ' ').title()}", "CustomNameVisible": byte(1)}
    return structure([placed(
        mob, -1, Persistent=byte(1),
        Tags=list_(STRING, ["kit_mob", f"kit_t{tier}"]),
        Armor=list_(COMPOUND, [s for _, s in armour]),
        Mainhand=list_(COMPOUND, [main]),
        Offhand=list_(COMPOUND, [off]),
        **extra,
    )])


def roll(prefix, tiers, weight):
    """A function that runs `<prefix>/t<n>` for one tier, drawn by weight."""
    pool = [(n, TIERS[n][weight]) for n in tiers if TIERS[n][weight]]
    total = sum(w for _, w in pool)
    lines = [f"scoreboard players random roll kitroll 1 {total}"]
    low = 1
    for n, w in pool:
        lines.append(f"execute if score roll kitroll matches {low}..{low + w - 1} run function {prefix}/t{n}")
        low += w
    return "\n".join(lines) + "\n"


def pick(paths):
    lines = [f"scoreboard players random pick kitroll 1 {len(paths)}"]
    lines += [f"execute if score pick kitroll matches {i} run function {p}" for i, p in enumerate(paths, 1)]
    return "\n".join(lines) + "\n"


def files():
    out = {}
    for role in ROLES:
        for tier in list(TIERS):
            out[f"structures/kit_{role}_t{tier}.mcstructure"] = kit_structure(role, tier)
            # The tag keeps a crew unit's own top-up (equip.mcfunction) off the kit.
            out[f"functions/kits/{role}/t{tier}.mcfunction"] = (
                f"structure load kit_{role}_t{tier} ~ ~ ~ 0_degrees none true false\n"
                f"scriptevent kits:arrange {TIERS[tier]['name']} {ROLES[role]['title']}\n"
                "tag @s add kitted\n").encode()
        out[f"functions/kits/{role}/roll.mcfunction"] = roll(f"kits/{role}", list(TIERS), "weight").encode()
        out[f"functions/kits/{role}/elite.mcfunction"] = roll(f"kits/{role}", list(TIERS), "elite").encode()
    out["functions/kits/random.mcfunction"] = pick([f"kits/{r}/roll" for r in ROLES]).encode()
    for mob in MOBS:
        for tier in list(TIERS):
            out[f"structures/mob_{mob}_t{tier}.mcstructure"] = mob_structure(mob, tier)
            out[f"functions/mobs/{mob}/t{tier}.mcfunction"] = (
                f"structure load mob_{mob}_t{tier} ~ ~ ~ 0_degrees none true false\n").encode()
        out[f"functions/mobs/{mob}/roll.mcfunction"] = roll(f"mobs/{mob}", list(TIERS), "weight").encode()
        out[f"functions/mobs/{mob}/elite.mcfunction"] = roll(f"mobs/{mob}", list(TIERS), "elite").encode()
    out["functions/mobs/random.mcfunction"] = pick([f"mobs/{m}/roll" for m in MOBS]).encode()
    return out


def tarball(contents):
    """A gzipped tar that is byte-identical on every run, so the test can
    compare it with the committed one."""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for path in sorted(contents):
            info = tarfile.TarInfo(path)
            info.size, info.mode, info.mtime = len(contents[path]), 0o644, 0
            tar.addfile(info, io.BytesIO(contents[path]))
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode="wb", mtime=0, filename="") as gz:
        gz.write(raw.getvalue())
    return out.getvalue()


def catalog():
    tier_rows = "\n".join(
        f"| {n} | {t['name']} | {t['armour']} | {t['metal']} | {t['weight']}% | {t['elite'] or '-'}{'%' if t['elite'] else ''} |"
        for n, t in TIERS.items())
    role_rows = "\n".join(
        f"| `{key}` | {r['title']} | {', '.join(title for _, title, _ in r['items'])} | "
        f"{', '.join(str(n) for n in list(TIERS))} |"
        for key, r in ROLES.items())
    mob_rows = "\n".join(f"| `{m}` | {ROLES[r]['title']} | {', '.join(str(n) for n in list(TIERS))} |" for m, r in MOBS.items())
    kits = sum(len(list(TIERS)) for r in ROLES)
    mobs = sum(len(list(TIERS)) for r in MOBS.values())
    return f"""# Crew lab kit catalog

Generated by `tools/crew-lab-kits.py`; edit the tables there, not here.
{kits} role kits and {mobs} mob kits.

## Handing them out (lab console)

| Command | Gives |
|---|---|
| `execute as <player> at @s run function kits/<role>/t<n>` | that role's tier-n kit |
| `execute as <player> at @s run function kits/<role>/roll` | that role, tier drawn by the roll weights |
| `execute as <player> at @s run function kits/<role>/elite` | that role, tier 4-6 by the elite weights |
| `execute as <player> at @s run function kits/random` | a random role, rolled tier |
| `execute positioned <x> <y> <z> run function mobs/<mob>/t<n>` | one geared mob there |
| `execute positioned <x> <y> <z> run function mobs/<mob>/roll` (or `elite`) | one mob, rolled tier |
| `execute positioned <x> <y> <z> run function mobs/random` | a random mob, rolled tier |

A player kit drops at the player's feet; about 2 s later the pack's script
puts the armour on, the weapons and tools in the hotbar in a fixed order and
the shield in the off hand, swapping out what was there. It also tags the
player `kitted`, which stops a crew unit's own iron or diamond top-up from
replacing the kit. Mobs spawn persistent and tagged `kit_mob` and
`kit_t<n>`; tier 4 and up are named. Gear a kit mob drops is deleted, so the
arena is not a netherite farm.

## Tiers

| Tier | Name | Armour | Tools | Roll | Elite roll |
|---|---|---|---|---|---|
{tier_rows}

Enchantment levels scale with the tier: none at 1, the role's signature
enchantments at level 1 at 2, half of max at 3, one below max at 4, max at 5
and 6. Unbreaking from tier 3, Mending from tier 5 (never on an Infinity
bow). Armour from tier 3 carries the role's trim (copper, amethyst, diamond,
gold). Tier 6 adds enchanted golden apples and a second totem.

## Roles

| Key | Role | Items | Tiers |
|---|---|---|---|
{role_rows}

## Mobs

| Key | Dressed as | Tiers |
|---|---|---|
{mob_rows}
"""


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    chart = os.path.join(here, "..", "charts", "crew-lab")
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(chart, "files", "kits.tar.gz")
    doc = sys.argv[2] if len(sys.argv) > 2 else os.path.join(chart, "KITS.md")
    with open(out, "wb") as f:
        f.write(tarball(files()))
    with open(doc, "w") as f:
        f.write(catalog())
