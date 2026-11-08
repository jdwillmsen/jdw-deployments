#!/usr/bin/env python3
"""Console commands that build the proving-grounds laboratory.

  proving-grounds-lab.py build   [wildlife|safety|arena|supply|plaza|all]
  proving-grounds-lab.py clear

Prints one console command per line; tools/proving-grounds-lab pipes them into
the server. The flat world's grass top is y -61, so floors are laid at y -61 and
players stand at y -60. Re-running a section rebuilds its blocks but adds its mobs and labels
again; `build all` clears them first, or run `clear` before a single section.

Layout (x east, z south), all around the spawn plaza:
  plaza    x -14..14   z -14..14
  wildlife x -34..34   z -75..-28   six 16x16 glass pens, one species each
  safety   x -62..-34  z -14..14    the two-client pet safety room
  arena    x  29..85   z -28..28    sealed glass dome: brute, werewolf and ground dragon
  supply   x -14..14   z  15..31    food, gear, armor, eggs and a command sheet
  breeding x -37..-4   z  38..62    six open stalls, one pair of adults each
  armor    x   4..36   z  38..62    armor fitting bay with a podium per tier
Roofs are left open on purpose: fly in from above in creative. The arena dome keeps a wide hole at the top
(mobs are ground-bound and the hole is 24 blocks up).
"""
import math
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
SPAWNABLE_IDS = [p[0] for p in PENS] + [s[0] for s in STAGE0]
VANILLA_MOBS = ["zombie", "skeleton", "creeper", "wolf", "horse", "sheep", "cow", "pig", "chicken", "rabbit"]
FOODS = ["beef", "rabbit", "mutton", "chicken", "salmon", "rotten_flesh"]


def fill(x1, y1, z1, x2, y2, z2, block, mode=""):
    yield f"fill {x1} {y1} {z1} {x2} {y2} {z2} {block} {mode}".strip()


def label(text, x, z, y=STAND):
    yield f'summon armor_stand "{text}" {x} {y} {z}'
    yield f"effect @e[type=armor_stand,x={x},y={y},z={z},r=0.1] invisibility 99999 0 true"


def board(lines, x, z, y=STAND):
    """Floating text: one invisible named stand per line, stacked upward, first line on top."""
    for i, text in enumerate(reversed(lines)):
        yield from label(text, x, z, round(y + 0.28 * i, 2))


def lectern(x, z):
    yield f"setblock {x} {STAND} {z} lectern"


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


def big_fill(x1, y1, z1, x2, y2, z2, block):
    """A fill split along y so no single command passes the 32768-block limit."""
    step = max(1, 30000 // ((x2 - x1 + 1) * (z2 - z1 + 1)))
    y = y1
    while y <= y2:
        top = min(y2, y + step - 1)
        yield from fill(x1, y, z1, x2, top, z2, block)
        y = top + 1


def disc(cx, cz, r, y, block):
    for dx in range(-r, r + 1):
        h = int(math.sqrt(r * r - dx * dx))
        yield from fill(cx + dx, y, cz - h, cx + dx, y, cz + h, block)


def dome(cx, cz, r, y0, block="glass"):
    """A glass hemisphere (about two blocks thick) of radius r standing on layer y0. Columns with identical
    spans are merged so a layer costs a handful of commands, not one per column."""
    # the top layers are left out: a wide hole to fly in through. Mobs here are ground-bound and it is 24 blocks up.
    for h in range(r - DOME_OPEN):
        outer = r * r - h * h
        # thinner than about 1.7 blocks leaves diagonal gaps that a mob can squeeze through
        inner = (r - 1.8) ** 2 - h * h
        spans = {}
        for dx in range(-r, r + 1):
            rest = outer - dx * dx
            if rest < 0:
                continue
            zo = int(math.sqrt(rest))
            v = inner - dx * dx
            if v < 0:
                spans[dx] = ((-zo, zo),)
            else:
                zi = int(math.sqrt(v)) + 1
                spans[dx] = ((-zo, -zi), (zi, zo)) if zi <= zo else ()
        xs = sorted(spans)
        i = 0
        while i < len(xs):
            j = i
            while j + 1 < len(xs) and xs[j + 1] == xs[j] + 1 and spans[xs[j + 1]] == spans[xs[i]]:
                j += 1
            for z1, z2 in spans[xs[i]]:
                yield from fill(cx + xs[i], y0 + h, cz + z1, cx + xs[j], y0 + h, cz + z2, block)
            i = j + 1


ARENA_CX, ARENA_CZ, ARENA_R = 57, 0, 28
DOME_OPEN = 2  # layers left off the top of the dome
PAD = (24, 26)  # the teleport pad outside the dome: x range, z -1..1


def clear():
    for t in ("armor_stand", "item"):
        yield f"kill @e[type={t},x=-70,y=-64,z=-80,dx=160,dy=40,dz=155]"
    # vanilla mobs a tester spawned from the egg chest
    for sp in VANILLA_MOBS:
        yield f"kill @e[type={sp},x=-70,y=-64,z=-80,dx=160,dy=40,dz=155]"
    for sp in [p[0] for p in PENS] + [s[0] for s in STAGE0]:
        yield f"kill @e[type=gameops:{sp},x=-70,y=-64,z=-80,dx=160,dy=40,dz=155]"


def plaza():
    yield from fill(-14, STAND, -14, 14, STAND + 8, 14, "air")
    yield from fill(-14, FLOOR, -14, 14, FLOOR, 14, "light_gray_concrete")
    # quadrants in the colour of the area they lead to
    yield from fill(-13, FLOOR, -13, -1, FLOOR, -1, "lime_concrete")
    yield from fill(1, FLOOR, -13, 13, FLOOR, -1, "red_concrete")
    yield from fill(-13, FLOOR, 1, -1, FLOOR, 13, "yellow_concrete")
    yield from fill(1, FLOOR, 1, 13, FLOOR, 13, "blue_concrete")
    # border and cross
    yield from fill(-14, FLOOR, -14, 14, FLOOR, -14, "quartz_block")
    yield from fill(-14, FLOOR, 14, 14, FLOOR, 14, "quartz_block")
    yield from fill(-14, FLOOR, -14, -14, FLOOR, 14, "quartz_block")
    yield from fill(14, FLOOR, -14, 14, FLOOR, 14, "quartz_block")
    yield from fill(-14, FLOOR, -1, 14, FLOOR, 1, "quartz_block")
    yield from fill(-1, FLOOR, -14, 1, FLOOR, 14, "quartz_block")
    yield from fill(-3, FLOOR, -3, 3, FLOOR, 3, "white_concrete")
    # a lit obelisk at the centre
    yield from fill(0, STAND, 0, 0, STAND + 5, 0, "quartz_pillar")
    yield f"setblock 0 {STAND + 6} 0 sea_lantern"
    # corner towers
    for x in (-13, 13):
        for z in (-13, 13):
            yield from fill(x, STAND, z, x, STAND + 4, z, "quartz_block")
            yield f"setblock {x} {STAND + 5} {z} sea_lantern"
    for x in (-8, 8):
        for z in (-8, 8):
            yield f"setblock {x} {FLOOR} {z} sea_lantern"
    # gateways: a lintel over each exit, coloured like its quadrant
    yield from fill(-3, STAND + 3, -14, 3, STAND + 3, -14, "lime_concrete")
    yield from fill(-3, STAND, -14, -3, STAND + 2, -14, "quartz_block")
    yield from fill(3, STAND, -14, 3, STAND + 2, -14, "quartz_block")
    yield from fill(-14, STAND + 3, -3, -14, STAND + 3, 3, "blue_concrete")
    yield from fill(-14, STAND, -3, -14, STAND + 2, -3, "quartz_block")
    yield from fill(-14, STAND, 3, -14, STAND + 2, 3, "quartz_block")
    yield from fill(14, STAND + 3, -3, 14, STAND + 3, 3, "red_concrete")
    yield from fill(14, STAND, -3, 14, STAND + 2, -3, "quartz_block")
    yield from fill(14, STAND, 3, 14, STAND + 2, 3, "quartz_block")
    yield from fill(-3, STAND + 3, 14, 3, STAND + 3, 14, "yellow_concrete")
    yield from fill(-3, STAND, 14, -3, STAND + 2, 14, "quartz_block")
    yield from fill(3, STAND, 14, 3, STAND + 2, 14, "quartz_block")
    # stepped dais round the obelisk
    yield from fill(-2, STAND, -2, 2, STAND, 2, "smooth_quartz")
    yield from fill(-1, STAND + 1, -1, 1, STAND + 1, 1, "chiseled_quartz_block")
    yield from fill(0, STAND + 2, 0, 0, STAND + 7, 0, "quartz_pillar")
    yield from fill(0, STAND + 8, 0, 0, STAND + 8, 0, "sea_lantern")
    # lamp posts along the four paths so each way out is visibly lit
    # none south of the plaza: the supply room is built over that stretch and would clear them
    posts = [(sx * 2, z) for sx in (-1, 1) for z in (-20, -26)]
    posts += [(x, sz * 2) for sz in (-1, 1) for x in (-20, -26, 19, 30)]
    for x, z in posts:
        yield from fill(x, STAND, z, x, STAND + 2, z, "quartz_pillar")
        yield f"setblock {x} {STAND + 3} {z} sea_lantern"
    # coloured runway down each path, matching the quadrant it leads to
    yield from fill(0, FLOOR, -28, 0, FLOOR, -15, "lime_concrete")
    yield from fill(-30, FLOOR, 0, -15, FLOOR, 0, "blue_concrete")
    yield from fill(15, FLOOR, 0, 33, FLOOR, 0, "red_concrete")
    yield from fill(0, FLOOR, 15, 0, FLOOR, 15, "yellow_concrete")
    # paths out
    yield from fill(-2, FLOOR, -28, 2, FLOOR, -15, "light_gray_concrete")
    yield from fill(-30, FLOOR, -2, -15, FLOOR, 2, "light_gray_concrete")
    yield from fill(15, FLOOR, -2, 33, FLOOR, 2, "light_gray_concrete")
    yield from fill(-2, FLOOR, 15, 2, FLOOR, 15, "light_gray_concrete")
    yield from lectern(0, -5)
    yield from board(["\u00a7bYard", "breeding + armor bays", "south, past the supply room"], 0, 13)
    yield from board(["\u00a7lPROVING GROUNDS", "Add-on test world", "Right-click the lectern for the guide"], 0, 3)
    yield from board(["\u00a7aWildlife preserve", "tamable animals"], 0, -11)
    yield from board(["\u00a79Safety lab", "two-player pet tests"], -11, 0)
    yield from board(["\u00a7cBoss arena", "brute, werewolf, dragon"], 11, 0)
    yield from board(["\u00a7eSupply room", "food, gear, eggs"], 0, 11)


def wildlife():
    yield from fill(-36, FLOOR, -76, 36, FLOOR, -27, "light_gray_concrete")
    yield from fill(-36, STAND, -76, 36, STAND + 7, -27, "air")
    for species, food, count, (cx, cz) in PENS:
        x1, x2, z1, z2 = cx - 8, cx + 8, cz - 8, cz + 8
        yield from fill(x1, FLOOR, z1, x2, FLOOR, z2, "grass_block")
        # open roof: fly in from above. Six glass blocks is more than any of these animals can jump.
        yield from walls(x1, z1, x2, z2, 6, "glass")
        for px, pz in ((x1, z1), (x1, z2), (x2, z1), (x2, z2)):
            yield from fill(px, STAND, pz, px, STAND + 6, pz, "quartz_pillar")
        # the gate faces the aisle on the south wall; the glass above it stays so nothing can jump out
        yield from fill(cx - 1, STAND, z2, cx + 1, STAND + 1, z2, "air")
        for gx in (cx - 1, cx, cx + 1):
            yield f"setblock {gx} {STAND} {z2} fence_gate"
        yield from chest(cx - 6, STAND, cz + 6, [(food, 32), ("lead", 4), ("name_tag", 2), ("bone", 8)])
        yield from board([species.replace("_", " ").title(), "tames with " + food.replace("_", " ")], cx, z2 + 1)
        yield from lectern(cx + 3, z2 + 1)
        for i in range(count):
            yield f"summon gameops:{species} {cx - 2 + 3 * (i % 2)} {STAND} {cz - 2 + 2 * (i // 2)}"


def safety():
    yield from fill(-62, FLOOR, -14, -34, FLOOR, 14, "white_concrete")
    yield from room(-62, -14, -34, 14, 6, "quartz_block")
    yield from fill(-34, STAND, -1, -34, STAND + 2, 1, "air")
    # player pads and the rival cage in the middle
    yield from fill(-58, FLOOR, -11, -55, FLOOR, -8, "blue_concrete")
    yield from fill(-58, FLOOR, 8, -55, FLOOR, 11, "red_concrete")
    yield from label("Player A pad", -57, -9)
    yield from label("Player B pad", -57, 9)
    yield from walls(-48, -4, -40, 4, 5, "glass")
    yield from fill(-48, FLOOR, -4, -40, FLOOR, 4, "grass_block")
    yield from label("Rival cage: lion vs hyena", -44, -5)
    yield f"summon gameops:lion -46 {STAND} 0"
    yield f"summon gameops:hyena -42 {STAND} 0"
    yield from chest(-36, STAND, -12, [(f, 32) for f in FOODS] + [("lead", 4), ("golden_apple", 4), ("diamond_sword", 1)])
    yield from label("Tame with the food here", -36, -11)
    yield from lectern(-36, -9)
    yield from board(["Safety checks", "B hits owner / owner hits B", "owner hits pet / sitting pet"], -48, 12)


def arena():
    cx, cz, r = ARENA_CX, ARENA_CZ, ARENA_R
    yield from big_fill(cx - r - 1, STAND, cz - r - 1, cx + r + 1, STAND + r + 1, cz + r + 1, "air")
    yield from disc(cx, cz, r, FLOOR, "black_concrete")
    yield from disc(cx, cz, 4, FLOOR, "white_concrete")
    for k in range(12):
        a = k * math.pi / 6
        yield f"setblock {cx + round(20 * math.cos(a))} {FLOOR} {cz + round(20 * math.sin(a))} sea_lantern"
    yield from dome(cx, cz, r, STAND)
    for name, x in STAGE0:
        yield from fill(x - 2, FLOOR, -14, x + 2, FLOOR, -10, "quartz_block")
        yield from label(name.replace("_", " "), x, -9)
        yield f"summon gameops:{name} {x} {STAND} -12"
    yield from lectern(34, -4)
    yield from board(["They hunt only players with the arena_warrior tag", "Toggle it from the lectern or any book"], cx, 12)
    # the dome is sealed: a pad outside carries players in, a pad inside carries them out
    yield from fill(PAD[0], FLOOR, -1, PAD[1], FLOOR, 1, "sea_lantern")
    yield from fill(PAD[0] - 1, FLOOR, -2, PAD[1] + 1, FLOOR, -2, "quartz_block")
    yield from fill(PAD[0] - 1, FLOOR, 2, PAD[1] + 1, FLOOR, 2, "quartz_block")
    yield from board(["\u00a7cBOSS ARENA", "Step on the lit pad", "to be carried inside"], PAD[0] - 2, 0)
    yield from fill(33, FLOOR, -1, 35, FLOOR, 1, "sea_lantern")
    yield from board(["Step on the lit pad", "to leave the dome"], 33, 3)


ARMORS = ["leather_horse_armor", "iron_horse_armor", "diamond_horse_armor"]
SUPPLY_CHESTS = [
    # x, label, contents
    (-12, "Food for taming", [(f, 64) for f in FOODS]),
    (-10, "More food", [("cooked_beef", 32), ("cooked_chicken", 32), ("golden_carrot", 16), ("apple", 16), ("bread", 16),
                         ("bone", 32), ("wheat", 16), ("carrot", 16), ("milk_bucket", 1), ("bucket", 1)]),
    (-8, "Gear", [("diamond_sword", 1), ("diamond_helmet", 1), ("diamond_chestplate", 1), ("diamond_leggings", 1),
                   ("diamond_boots", 1), ("shield", 1), ("bow", 1), ("arrow", 64), ("golden_apple", 16),
                   ("totem_of_undying", 1)]),
    (-6, "Weapons to compare damage", [("wooden_sword", 1), ("stone_sword", 1), ("iron_sword", 1), ("diamond_sword", 1),
                                        ("netherite_sword", 1), ("iron_axe", 1), ("trident", 1), ("crossbow", 1),
                                        ("bow", 1), ("arrow", 64), ("spectral_arrow", 32), ("flint_and_steel", 1)]),
    (-4, "Animal armor", [(a, 4) for a in ARMORS] + [("saddle", 2), ("lead", 8), ("name_tag", 8)]),
    (-2, "Tools", [("compass", 1), ("clock", 1), ("spyglass", 1), ("elytra", 1), ("firework_rocket", 64),
                    ("shears", 1), ("fishing_rod", 1), ("water_bucket", 1), ("lava_bucket", 1), ("cobweb", 8),
                    ("torch", 64), ("oak_planks", 64), ("white_wool", 16), ("oak_fence", 16), ("fence_gate", 8),
                    ("hay_block", 16)]),
]
EGGS_AT = 6


def supply():
    yield from fill(-14, FLOOR, 15, 14, FLOOR, 31, "white_concrete")
    yield from room(-14, 15, 14, 31, 5, "quartz_block")
    yield from fill(-2, STAND, 15, 2, STAND + 3, 15, "air")
    # a south door leads on to the yard
    yield from fill(-2, STAND, 31, 2, STAND + 3, 31, "air")
    yield from fill(0, FLOOR, 16, 0, FLOOR, 31, "yellow_concrete")
    for x, name, items in SUPPLY_CHESTS:
        yield from chest(x, STAND, 29, items)
        yield from label(name, x, 28)
    # spawn eggs: every mob, plus a second chest with the cub-friendly extras
    yield from chest(EGGS_AT, STAND, 29, [(f"gameops:{sp}_spawn_egg", 16) for sp in SPAWNABLE_IDS] + [("book", 4)])
    yield from label("Spawn eggs and guide books", EGGS_AT, 28)
    yield from chest(EGGS_AT + 2, STAND, 29, [(f"{m}_spawn_egg", 4) for m in VANILLA_MOBS])
    yield from label("Vanilla mobs: prey, rivals, riders", EGGS_AT + 2, 28)
    # lanterns set into the side walls, built after the room so nothing clears them
    for z in (18, 24):
        for x in (-14, 14):
            yield f"setblock {x} {STAND + 3} {z} sea_lantern"
    yield from lectern(0, 17)
    yield from board(["Supply room", "Right-click the lectern, or hold a book"], 0, 22)


def yard_stall(cx, cz, species, food):
    """One open-top breeding stall: grass, glass walls, two adults, and a chest of food. The gate is on the aisle side."""
    x1, x2, z1, z2 = cx - 5, cx + 5, cz - 5, cz + 5
    yield from fill(x1, FLOOR, z1, x2, FLOOR, z2, "grass_block")
    yield from fill(x1, STAND, z1, x2, STAND + 6, z2, "air")
    yield from walls(x1, z1, x2, z2, 5, "glass")
    for px, pz in ((x1, z1), (x1, z2), (x2, z1), (x2, z2)):
        yield from fill(px, STAND, pz, px, STAND + 5, pz, "quartz_pillar")
    yield from chest(cx + (4 if cx < 0 else -4), STAND, cz, [(food, 64), ("lead", 4), ("name_tag", 2), ("wheat", 8)])


BREED_STALLS = [
    ("tiger", "beef", -31, 43, "south"), ("cheetah", "rabbit", -20, 43, "south"), ("lion", "mutton", -9, 43, "south"),
    ("black_leopard", "chicken", -31, 57, "north"), ("brown_bear", "salmon", -20, 57, "north"),
    ("hyena", "rotten_flesh", -9, 57, "north"),
]


def breeding():
    yield from fill(-38, FLOOR, 37, -3, FLOOR, 63, "light_gray_concrete")
    yield from fill(-38, STAND, 37, -3, STAND + 8, 63, "air")
    for species, food, cx, cz, gate in BREED_STALLS:
        yield from yard_stall(cx, cz, species, food)
        gz = cz + 5 if gate == "south" else cz - 5
        yield from fill(cx - 1, STAND, gz, cx + 1, STAND + 1, gz, "air")
        for gx in (cx - 1, cx, cx + 1):
            yield f"setblock {gx} {STAND} {gz} fence_gate"
        sz = gz + 1 if gate == "south" else gz - 1
        yield from board([species.replace("_", " ").title(), "tame both, then feed", food.replace("_", " ")], cx, sz)
        for i in range(2):
            yield f"summon gameops:{species} {cx - 1 + 2 * i} {STAND} {cz - 2}"
    # the walkway from the supply room's south door, with the armor bay's entrance at its far end
    yield from fill(-2, FLOOR, 32, 2, FLOOR, 36, "light_gray_concrete")
    yield from fill(-2, FLOOR, 37, 1, FLOOR, 63, "light_gray_concrete")
    yield from fill(0, FLOOR, 32, 0, FLOOR, 50, "yellow_concrete")
    for z in (34, 42, 58):
        for x in (-2, 2 if z < 37 else 1):
            yield from fill(x, STAND, z, x, STAND + 2, z, "quartz_pillar")
            yield f"setblock {x} {STAND + 3} {z} sea_lantern"
    yield from board(["\u00a7bYARD", "West: breeding", "East: armor bay"], 0, 35)
    # the aisle between the rows
    yield from fill(-38, FLOOR, 49, -3, FLOOR, 51, "yellow_concrete")
    yield from lectern(-3, 50)
    yield from board(["\u00a7eBREEDING YARD", "Tame two of a kind, feed both", "Hearts, then cubs", "Cubs keep the coat and the owner"], -34, 50)


ARMOR_TIERS = [("Leather", "leather_horse_armor", "0.8", 8), ("Iron", "iron_horse_armor", "0.6", 16),
               ("Diamond", "diamond_horse_armor", "0.4", 24)]


def armor():
    yield from fill(2, FLOOR, 37, 38, FLOOR, 63, "light_gray_concrete")
    yield from fill(2, STAND, 37, 38, STAND + 8, 63, "air")
    yield from walls(2, 37, 38, 63, 5, "glass")
    for px, pz in ((2, 37), (2, 63), (38, 37), (38, 63)):
        yield from fill(px, STAND, pz, px, STAND + 5, pz, "quartz_pillar")
    # entrance on the plaza side
    yield from fill(2, STAND, 49, 2, STAND + 3, 51, "air")
    yield from fill(2, FLOOR, 49, 8, FLOOR, 51, "yellow_concrete")
    for name, item, mult, x in ARMOR_TIERS:
        yield from fill(x - 2, FLOOR, 40, x + 2, FLOOR, 44, "quartz_block")
        yield from fill(x - 1, STAND, 41, x + 1, STAND, 43, "smooth_quartz")
        yield from chest(x, STAND, 40, [(item, 4), ("lead", 2), ("name_tag", 1)])
        yield from board([f"\u00a7e{name} tier", f"damage taken x{mult}", "chest: armor, lead"], x, 45)
    # a fitting row: three tamed-animal platforms with food, one per tier, plus a bare control
    yield from fill(6, FLOOR, 52, 34, FLOOR, 60, "smooth_quartz")
    for i, x in enumerate((9, 17, 25, 33)):
        yield from fill(x - 2, FLOOR, 53, x + 2, FLOOR, 59, "white_concrete" if i == 0 else "light_gray_concrete")
        yield from label("Control: no armor" if i == 0 else f"Fit: {ARMOR_TIERS[i - 1][0]}", x, 55)
        # fenced apart, so a tiger cannot wander onto the next tier's platform before it is tamed
        yield from walls(x - 3, 52, x + 3, 60, 4, "glass")
        yield from fill(x - 1, STAND, 52, x + 1, STAND + 1, 52, "air")
        for gx in (x - 1, x, x + 1):
            yield f"setblock {gx} {STAND} 52 fence_gate"
        yield f"summon gameops:tiger {x} {STAND} 57"
    yield from chest(21, STAND, 60, [("beef", 64), ("golden_apple", 8), ("diamond_sword", 1), ("iron_sword", 1),
                                      ("wooden_sword", 1), ("bow", 1), ("arrow", 64)])
    yield from label("Beef, swords and a bow", 21, 59)
    yield from lectern(36, 50)
    yield from board(["\u00a7bARMOR BAY", "Tame a tiger, fit armor", "Hit all four the same", "Armor takes less"], 36, 47)


SECTIONS = {"plaza": plaza, "wildlife": wildlife, "safety": safety, "arena": arena, "supply": supply,
            "breeding": breeding, "armor": armor}
RULES = ["gamerule domobspawning false", "gamerule doweathercycle false", "gamerule keepinventory true",
         "gamerule showcoordinates true", "gamerule mobgriefing false", "time set day", "setworldspawn 0 -60 8"]


def main(argv):
    if len(argv) < 2 or argv[1] not in ("build", "clear"):
        sys.exit(__doc__)
    if argv[1] == "clear":
        out = list(clear())
    else:
        which = argv[2] if len(argv) > 2 else "all"
        names = list(SECTIONS) if which == "all" else [which]
        # a ticking area holds at most 100 chunks, so the yard to the south gets its own
        out = ["tickingarea add -70 -64 -80 90 -50 35 pg_lab", "tickingarea add -70 -64 36 90 -50 70 pg_yard"]
        out += list(clear()) if which == "all" else []
        for n in names:
            out += list(SECTIONS[n]())
        out += RULES if which == "all" else []
        out += ["testforblock 0 -61 0 smooth_stone"]
    print("\n".join(out))


if __name__ == "__main__":
    main(sys.argv)
