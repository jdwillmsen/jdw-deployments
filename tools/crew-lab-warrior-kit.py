#!/usr/bin/env python3
"""Writes charts/crew-lab/files/warrior_<role>_kit.mcstructure: the enchanted
kit of a squad warrior (vanguard, striker or ranger) as dropped items, so
loading it at the warrior's feet puts it straight into its inventory.

Bedrock has no command that enchants an item, so a structure is the only way
to hand a unit enchanted gear. The NBT writer is the Dota kit's.

Usage: tools/crew-lab-warrior-kit.py [output-path vanguard|striker|ranger]
Without arguments it writes all three roles into the chart.
"""
import importlib.util
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
# The Dota tool's file name is not importable as a module.
spec = importlib.util.spec_from_file_location("dota_kit", os.path.join(here, "crew-lab-dota-kit.py"))
dota = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dota)

ARMOR = [("diamond_" + p, [("protection", 4), ("unbreaking", 3)]) for p in ("helmet", "chestplate", "leggings", "boots")]
SWORD = ("diamond_sword", [("sharpness", 5), ("unbreaking", 3)])
BOW = ("bow", [("power", 5), ("unbreaking", 3)])
SHIELD = ("shield", [("unbreaking", 3)])

# Item, enchantments, count. The offhand piece is the one thing a Bedrock
# player can hold while a sword is drawn.
ROLES = {
    "vanguard": {"uid": -0x57A11000, "items": ARMOR + [SWORD, SHIELD]},
    "striker": {"uid": -0x57A12000, "items": ARMOR + [SWORD, ("totem_of_undying", [])]},
    "ranger": {"uid": -0x57A13000, "items": ARMOR + [SWORD, BOW, ("totem_of_undying", [])]},
}
APPLES = 16
ARROWS = 64


def item(name, enchants, count=1):
    it = {"Name": "minecraft:" + name, "Count": dota.byte(count), "Damage": dota.short(0), "WasPickedUp": dota.byte(0)}
    if enchants:
        it["tag"] = {"ench": dota.list_(dota.COMPOUND, [{"id": dota.short(dota.ENCHANT[e]), "lvl": dota.short(lvl)} for e, lvl in enchants])}
    return it


def build(role="vanguard"):
    kit = ROLES[role]
    items = [item(name, enchants) for name, enchants in kit["items"]]
    items.append(item("golden_apple", [], APPLES))
    if role == "ranger":
        items.append(item("arrow", [], ARROWS))
    entities = [dota.dropped({"uid": kit["uid"]}, n, it) for n, it in enumerate(items)]
    return dota.structure(entities)


if __name__ == "__main__":
    files = os.path.join(here, "..", "charts", "crew-lab", "files")
    roles = [sys.argv[2]] if len(sys.argv) > 2 else list(ROLES)
    for role in roles:
        out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(files, f"warrior_{role}_kit.mcstructure")
        with open(out, "wb") as f:
            f.write(build(role))
