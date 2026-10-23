#!/usr/bin/env python3
"""Writes charts/crew-lab/files/<kit>_kit.mcstructure: a player's named, enchanted
and trimmed kit as dropped items, so loading it at their feet puts it
straight into their inventory. Kits: dota (Dotablaze), lightking (LightKing0221,
with the name tag and bones for his dog).

Bedrock has no command that names, trims or patterns an item, so a structure
is the only way to hand out such items without a player at an anvil or loom.

Usage: tools/crew-lab-dota-kit.py [output-path [dota|lightking]]
"""
import os
import struct
import sys

# Bedrock NBT is little-endian. Only the tag types this file needs.
BYTE, SHORT, INT, LONG, FLOAT, STRING, LIST, COMPOUND = 1, 2, 3, 4, 5, 8, 9, 10


class Tag:
    def __init__(self, kind, value, elem=None):
        self.kind, self.value, self.elem = kind, value, elem


def byte(v): return Tag(BYTE, v)
def short(v): return Tag(SHORT, v)
def int_(v): return Tag(INT, v)
def long_(v): return Tag(LONG, v)
def float_(v): return Tag(FLOAT, v)
def list_(elem, items): return Tag(LIST, items, elem)


def tag(v):
    if isinstance(v, Tag):
        return v
    if isinstance(v, str):
        return Tag(STRING, v)
    if isinstance(v, dict):
        return Tag(COMPOUND, v)
    raise TypeError(v)


def payload(t):
    if t.kind == BYTE: return struct.pack("<b", t.value)
    if t.kind == SHORT: return struct.pack("<h", t.value)
    if t.kind == INT: return struct.pack("<i", t.value)
    if t.kind == LONG: return struct.pack("<q", t.value)
    if t.kind == FLOAT: return struct.pack("<f", t.value)
    if t.kind == STRING:
        raw = t.value.encode()
        return struct.pack("<H", len(raw)) + raw
    if t.kind == LIST:
        out = struct.pack("<bi", t.elem if t.value else 0, len(t.value))
        return out + b"".join(payload(tag(x)) for x in t.value)
    out = b""
    for key, x in t.value.items():
        x, raw = tag(x), key.encode()
        out += struct.pack("<bH", x.kind, len(raw)) + raw + payload(x)
    return out + b"\x00"


# Bedrock's numeric enchantment ids.
ENCHANT = dict(
    protection=0, feather_falling=2, thorns=5, respiration=6, depth_strider=7,
    aqua_affinity=8, sharpness=9, knockback=12, fire_aspect=13, looting=14,
    efficiency=15, silk_touch=16, unbreaking=17, fortune=18, power=19, punch=20,
    flame=21, infinity=22, luck_of_the_sea=23, lure=24, mending=26, impaling=29,
    loyalty=31, channeling=32, multishot=33, quick_charge=35, soul_speed=36,
    swift_sneak=37, wind_burst=38, density=39, lunge=41,
)
LASTING = [("unbreaking", 3), ("mending", 1)]

# § codes: l bold, k obfuscated, r reset, o italic; 4/6/c/e/b/7 are colours.
SPARK = "§r§e§k!!§r"

# Banner colours are inverted dye ids: 0 black, 1 red, 11 yellow, 14 orange,
# 15 white.
THEMES = {
    "dota": {
        "owner": "Dota's",
        "title": "§l§c",
        "colour": {"armor": "§6", "weapon": "§e", "tool": "§b"},
        "lore": {"armor": "Forged in the blaze", "weapon": "Burns with blaze fire", "tool": "Blaze-tempered"},
        "banner": {
            "Base": int_(0),
            "Type": int_(0),
            "Patterns": list_(COMPOUND, [
                {"Pattern": "gru", "Color": int_(1)},
                {"Pattern": "bts", "Color": int_(14)},
                {"Pattern": "mr", "Color": int_(14)},
                {"Pattern": "flo", "Color": int_(11)},
                {"Pattern": "tts", "Color": int_(0)},
                {"Pattern": "bo", "Color": int_(0)},
            ]),
        },
        "trim": {"Material": "gold", "Pattern": "silence"},
        "uid": -0x0D07A000,
        "extras": [],
    },
    "lightking": {
        "owner": "Light King's",
        "title": "§l§f",
        "colour": {"armor": "§e", "weapon": "§f", "tool": "§b"},
        "lore": {"armor": "Woven from daylight", "weapon": "Cuts like a sunbeam", "tool": "Sun-tempered"},
        "banner": {
            "Base": int_(15),
            "Type": int_(0),
            "Patterns": list_(COMPOUND, [
                {"Pattern": "cr", "Color": int_(11)},
                {"Pattern": "mc", "Color": int_(11)},
                {"Pattern": "bo", "Color": int_(15)},
            ]),
        },
        "trim": {"Material": "quartz", "Pattern": "sentry"},
        "uid": -0x11C47000,
        # The dog, Lumen, is spawned at the hub with armour already on; he
        # tames it with a bone. The tag is for later dogs.
        "extras": [
            {"Name": "minecraft:bone", "Count": byte(16), "Damage": short(0), "WasPickedUp": byte(0)},
            {"Name": "minecraft:name_tag", "Count": byte(1), "Damage": short(0), "WasPickedUp": byte(0),
             "tag": {"display": {"Name": "Lumen"}}},
        ],
    },
}

KIT = [
    ("netherite_helmet", "Helmet", "armor", [("protection", 4), ("respiration", 3), ("aqua_affinity", 1)]),
    ("netherite_chestplate", "Chestplate", "armor", [("protection", 4), ("thorns", 3)]),
    ("netherite_leggings", "Leggings", "armor", [("protection", 4), ("swift_sneak", 3)]),
    ("netherite_boots", "Boots", "armor", [("protection", 4), ("feather_falling", 4), ("depth_strider", 3), ("soul_speed", 3)]),
    ("shield", "Shield", "armor", []),
    ("netherite_sword", "Sword", "weapon", [("sharpness", 5), ("looting", 3), ("fire_aspect", 2), ("knockback", 2)]),
    ("netherite_axe", "Axe", "weapon", [("sharpness", 5), ("efficiency", 5)]),
    ("mace", "Mace", "weapon", [("density", 5), ("wind_burst", 3), ("fire_aspect", 2)]),
    ("netherite_spear", "Spear", "weapon", [("sharpness", 5), ("lunge", 3), ("looting", 3), ("fire_aspect", 2), ("knockback", 2)]),
    ("trident", "Trident", "weapon", [("impaling", 5), ("loyalty", 3), ("channeling", 1)]),
    # Infinity and Mending exclude each other; Infinity wins on a bow.
    ("bow", "Bow", "weapon", [("power", 5), ("punch", 2), ("flame", 1), ("infinity", 1), ("unbreaking", 3)]),
    ("crossbow", "Crossbow", "weapon", [("quick_charge", 3), ("multishot", 1)]),
    ("netherite_pickaxe", "Fortune Pickaxe", "tool", [("efficiency", 5), ("fortune", 3)]),
    ("netherite_pickaxe", "Silk Pickaxe", "tool", [("efficiency", 5), ("silk_touch", 1)]),
    ("netherite_shovel", "Shovel", "tool", [("efficiency", 5), ("silk_touch", 1)]),
    ("netherite_hoe", "Hoe", "tool", [("efficiency", 5), ("fortune", 3)]),
    ("shears", "Shears", "tool", [("efficiency", 5)]),
    ("fishing_rod", "Fishing Rod", "tool", [("luck_of_the_sea", 3), ("lure", 3)]),
    ("flint_and_steel", "Flint and Steel", "tool", []),
    ("brush", "Brush", "tool", []),
]


def item(theme, name, title, kind, enchants, count=1):
    if name != "bow":
        enchants = enchants + LASTING
    extra = {}
    if name.startswith("netherite_") and kind == "armor":
        extra["Trim"] = dict(theme["trim"])
    if name == "shield":
        extra.update(theme["banner"])
    return {
        "Name": "minecraft:" + name,
        "Count": byte(count),
        "Damage": short(0),
        "WasPickedUp": byte(0),
        "tag": {
            "ench": list_(COMPOUND, [{"id": short(ENCHANT[e]), "lvl": short(lvl)} for e, lvl in enchants]),
            "display": {
                "Name": f"{SPARK} {theme['title']}{theme['owner']} {theme['colour'][kind]}{title} {SPARK}",
                "Lore": list_(STRING, [f"§r§7§o{theme['lore'][kind]}"]),
            },
            **extra,
        },
    }


def dropped(theme, n, it):
    return {
        "identifier": "minecraft:item",
        "Pos": list_(FLOAT, [float_(0.5), float_(0.0), float_(0.5)]),
        "Motion": list_(FLOAT, [float_(0.0)] * 3),
        "Rotation": list_(FLOAT, [float_(0.0)] * 2),
        "UniqueID": long_(theme["uid"] - n),
        "Item": it,
    }


def build(kit="dota"):
    theme = THEMES[kit]
    items = [item(theme, *k) for k in KIT]
    # The bow's Infinity needs one arrow; a full stack also feeds the crossbow.
    items.append({"Name": "minecraft:arrow", "Count": byte(64), "Damage": short(0), "WasPickedUp": byte(0)})
    items.extend(theme["extras"])
    root = {
        "format_version": int_(1),
        "size": list_(INT, [int_(1)] * 3),
        "structure_world_origin": list_(INT, [int_(0)] * 3),
        "structure": {
            "block_indices": list_(LIST, [list_(INT, [int_(-1)]), list_(INT, [int_(-1)])]),
            "entities": list_(COMPOUND, [dropped(theme, n, it) for n, it in enumerate(items)]),
            "palette": {"default": {"block_palette": list_(COMPOUND, []), "block_position_data": {}}},
        },
    }
    return struct.pack("<bH", COMPOUND, 0) + payload(tag(root))


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    kit = sys.argv[2] if len(sys.argv) > 2 else "dota"
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "charts", "crew-lab", "files", kit + "_kit.mcstructure")
    with open(out, "wb") as f:
        f.write(build(kit))
