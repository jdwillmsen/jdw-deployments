#!/usr/bin/env python3
"""Console commands that build the proving-grounds laboratory.

  proving-grounds-lab.py build   [wildlife|safety|arena|supply|plaza|all]
  proving-grounds-lab.py clear

Prints one console command per line; tools/proving-grounds-lab pipes them into
the server. The flat world's grass top is y -61, so floors are laid at y -61 and
players stand at y -60. Re-running a section rebuilds it in place.

Layout (x east, z south), all around the spawn plaza:
  plaza    x -14..14   z -14..14
  wildlife x -34..34   z -75..-28   six 16x16 glass pens, one species each
  safety   x -62..-34  z -14..14    the two-client pet safety room
  arena    x  34..82   z -24..24    brute, werewolf and ground dragon
  supply   x -14..14   z  15..31    food, gear and a command sheet
"""
import sys

FLOOR, STAND = -61, -60

# species -> (taming food, count); keys are the entity ids in the wildlife pack
PENS = [
    ("tiger", "beef", 2, (-24, -42)),
    ("cheetah", "rabbit", 2, (0, -42)),
    ("lion", "mutton", 2, (24, -42)),
    ("black_leopard", "chicken", 2, (-24, -66)),
    ("brown_bear", "salmon", 2, (0, -66)),
    ("hyena", "rotten_flesh", 4, (24, -66)),
]
STAGE0 = [("training_dummy_brute", 42), ("werewolf", 58), ("ground_dragon", 74)]
FOODS = ["beef", "rabbit", "mutton", "chicken", "salmon", "rotten_flesh"]


def fill(x1, y1, z1, x2, y2, z2, block, mode=""):
    yield f"fill {x1} {y1} {z1} {x2} {y2} {z2} {block} {mode}".strip()


def label(text, x, z, y=STAND):
    yield f'summon armor_stand "{text}" {x} {y} {z}'
    yield f"effect @e[type=armor_stand,x={x},y={y},z={z},r=1] invisibility 99999 0 true"


def chest(x, y, z, items):
    yield f"setblock {x} {y} {z} chest"
    for slot, (item, n) in enumerate(items):
        yield f"replaceitem block {x} {y} {z} slot.container {slot} {item} {n}"


def walls(x1, z1, x2, z2, h, block):
    """Four wall faces, h high, with no floor or roof (a hollow fill would add both)."""
    top = STAND + h - 1
    yield from fill(x1, STAND, z1, x2, top, z1, block)
    yield from fill(x1, STAND, z2, x2, top, z2, block)
    yield from fill(x1, STAND, z1, x1, top, z2, block)
    yield from fill(x2, STAND, z1, x2, top, z2, block)


def room(x1, z1, x2, z2, h, block):
    yield from fill(x1, STAND, z1, x2, STAND + h, z2, "air")
    yield from walls(x1, z1, x2, z2, h, block)


def clear():
    for t in ("armor_stand", "item"):
        yield f"kill @e[type={t},x=-70,y=-64,z=-80,dx=160,dy=40,dz=120]"
    for sp in [p[0] for p in PENS] + [s[0] for s in STAGE0]:
        yield f"kill @e[type=gameops:{sp},x=-70,y=-64,z=-80,dx=160,dy=40,dz=120]"


def plaza():
    yield from fill(-14, STAND, -14, 14, STAND + 6, 14, "air")
    yield from fill(-14, FLOOR, -14, 14, FLOOR, 14, "polished_andesite")
    yield from fill(-14, FLOOR, -14, 14, FLOOR, -14, "stone_bricks")
    yield from fill(-14, FLOOR, 14, 14, FLOOR, 14, "stone_bricks")
    yield from fill(-14, FLOOR, -14, -14, FLOOR, 14, "stone_bricks")
    yield from fill(14, FLOOR, -14, 14, FLOOR, 14, "stone_bricks")
    for x in (-8, 0, 8):
        for z in (-8, 0, 8):
            yield f"setblock {x} {FLOOR} {z} sea_lantern"
    yield from fill(-2, FLOOR, -2, 2, FLOOR, 2, "smooth_stone")
    # paths: north to the wildlife apron, west to safety, east to the arena, south to supply
    yield from fill(-2, FLOOR, -28, 2, FLOOR, -15, "light_gray_concrete")
    yield from fill(-30, FLOOR, -2, -15, FLOOR, 2, "light_gray_concrete")
    yield from fill(15, FLOOR, -2, 33, FLOOR, 2, "light_gray_concrete")
    yield from fill(-2, FLOOR, 15, 2, FLOOR, 15, "light_gray_concrete")
    yield from label("PROVING GROUNDS", 0, 0)
    yield from label("N: Wildlife preserve", 0, -12)
    yield from label("W: Safety lab (two clients)", -12, 0)
    yield from label("E: Boss arena", 12, 0)
    yield from label("S: Supply room", 0, 12)


def wildlife():
    yield from fill(-36, FLOOR, -76, 36, FLOOR, -27, "light_gray_concrete")
    yield from fill(-36, STAND, -76, 36, STAND + 7, -27, "air")
    for species, food, count, (cx, cz) in PENS:
        x1, x2, z1, z2 = cx - 8, cx + 8, cz - 8, cz + 8
        yield from fill(x1, FLOOR, z1, x2, FLOOR, z2, "grass_block")
        yield from walls(x1, z1, x2, z2, 5, "glass")
        # the gate faces the aisle on the south wall
        yield from fill(cx - 1, STAND, z2, cx + 1, STAND + 2, z2, "air")
        for gx in (cx - 1, cx, cx + 1):
            yield f"setblock {gx} {STAND} {z2} fence_gate"
        yield from chest(cx - 6, STAND, cz + 6, [(food, 32)])
        yield from label(species.replace("_", " ").title() + " (" + food.replace("_", " ") + ")", cx, z2 + 1)
        for i in range(count):
            yield f"summon gameops:{species} {cx - 2 + 3 * (i % 2)} {STAND} {cz - 2 + 2 * (i // 2)}"


def safety():
    yield from fill(-62, FLOOR, -14, -34, FLOOR, 14, "smooth_stone")
    yield from room(-62, -14, -34, 14, 6, "stone_bricks")
    yield from fill(-34, STAND, -1, -34, STAND + 2, 1, "air")
    # player pads and the rival cage in the middle
    yield from fill(-58, FLOOR, -11, -55, FLOOR, -8, "blue_concrete")
    yield from fill(-58, FLOOR, 8, -55, FLOOR, 11, "red_concrete")
    yield from label("Player A pad", -57, -9)
    yield from label("Player B pad", -57, 9)
    yield from walls(-48, -4, -40, 4, 4, "glass")
    yield from fill(-48, FLOOR, -4, -40, FLOOR, 4, "grass_block")
    yield from label("Rival cage: lion vs hyena", -44, -5)
    yield f"summon gameops:lion -46 {STAND} 0"
    yield f"summon gameops:hyena -42 {STAND} 0"
    yield from chest(-36, STAND, -12, [(f, 32) for f in FOODS])
    yield from label("Tame with the food here", -36, -11)
    yield from label("Safety: B hits owner, owner hits B, owner hits pet, sit and walk away", -48, 12)


def arena():
    yield from fill(32, FLOOR, -26, 82, FLOOR, 26, "smooth_sandstone")
    yield from room(32, -26, 82, 26, 11, "stone_bricks")
    yield from fill(32, STAND, -2, 32, STAND + 2, 2, "air")
    for bx, _ in [(40, 0), (60, 0), (80, 0)]:
        for z in (-24, 24):
            yield f"setblock {bx} {STAND + 5} {z} sea_lantern"
    for name, x in STAGE0:
        yield from fill(x - 2, FLOOR, -14, x + 2, FLOOR, -10, "quartz_block")
        yield from label(name.replace("_", " "), x, -9)
        yield f"summon gameops:{name} {x} {STAND} -12"
    yield from label("They hunt only the arena_warrior tag", 58, 10)
    yield from label("tag @s add arena_warrior  /  tag @s remove arena_warrior", 58, 12)


def supply():
    yield from fill(-14, FLOOR, 15, 14, FLOOR, 31, "smooth_stone")
    yield from room(-14, 15, 14, 31, 5, "stone_bricks")
    yield from fill(-2, STAND, 15, 2, STAND + 3, 15, "air")
    yield from chest(-10, STAND, 29, [(f, 64) for f in FOODS])
    yield from chest(-8, STAND, 29, [("diamond_sword", 1), ("diamond_helmet", 1), ("diamond_chestplate", 1),
                                      ("diamond_leggings", 1), ("diamond_boots", 1), ("shield", 1), ("bow", 1),
                                      ("arrow", 64), ("golden_apple", 16), ("totem_of_undying", 1)])
    yield from label("Food for taming", -10, 28)
    yield from label("Gear", -8, 28)
    yield from label("Ops: op <name> in the console, then /tag /summon /time /effect", 0, 20)
    yield from label("Test steps: see packs/lab-mods-wildlife README", 0, 22)


SECTIONS = {"plaza": plaza, "wildlife": wildlife, "safety": safety, "arena": arena, "supply": supply}
RULES = ["gamerule domobspawning false", "gamerule doweathercycle false", "gamerule keepinventory true",
         "gamerule showcoordinates true", "gamerule mobgriefing false", "time set day", "setworldspawn 0 -60 0"]


def main(argv):
    if len(argv) < 2 or argv[1] not in ("build", "clear"):
        sys.exit(__doc__)
    if argv[1] == "clear":
        out = list(clear())
    else:
        which = argv[2] if len(argv) > 2 else "all"
        names = list(SECTIONS) if which == "all" else [which]
        out = ["tickingarea add -70 -64 -80 90 -50 35 pg_lab"]
        out += list(clear()) if which == "all" else []
        for n in names:
            out += list(SECTIONS[n]())
        out += RULES if which == "all" else []
        out += ["testforblock 0 -61 0 smooth_stone"]
    print("\n".join(out))


if __name__ == "__main__":
    main(sys.argv)
