#!/usr/bin/env python3
"""Builds the crew lab's Colosseum as /fill commands for the lab console.

    tools/crew-lab-colosseum.py OUT_DIR [--against=OLD.npy] [--save=NEW.npy] [--feed=NS/POD]

writes build.cmds and arena.json (the arena director's layout). --against
emits only what differs from an earlier --save, as a patch. --feed runs the
commands on the lab server's console.

The arena is an ellipse centred on the lab's (0, -758). The model is voxelised
here and compressed into the fewest boxes, bottom layer first so sand always
lands on a solid block. The console runs about 20 commands a second.
"""
import math, os, sys, json
import numpy as np

ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
OUT = ARGS[0] if ARGS else "."
os.makedirs(OUT, exist_ok=True)
# --against OLD.npy emits only what differs from an earlier build, as a patch;
# --save NEW.npy keeps this build's voxels for the next patch.
OPT = {a.split("=")[0]: a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--") and "=" in a}

CX, CZ = 0, -758
X0, X1 = -112, 111          # build box, inside the four colo_* ticking areas
Z0, Z1 = -860, -637
Y0, Y1 = 63, 113             # y=63 is the grass (ground) layer; rel = y - 64
A0, B0 = 50, 36              # arena semi-axes
NB = 72                      # bays around the outer wall

W, H, D = X1 - X0 + 1, Y1 - Y0 + 1, Z1 - Z0 + 1
xs = np.arange(X0, X1 + 1)[None, :] - CX
zs = np.arange(Z0, Z1 + 1)[:, None] - CZ
xs = np.broadcast_to(xs, (D, W)).astype(float)
zs = np.broadcast_to(zs, (D, W)).astype(float)

# d = distance beyond the arena ellipse measured as an offset ellipse (a0+d, b0+d)
lo = np.full(xs.shape, -B0 + 0.01)
hi = np.full(xs.shape, 400.0)
for _ in range(50):
    mid = (lo + hi) / 2
    f = (xs / (A0 + mid)) ** 2 + (zs / (B0 + mid)) ** 2
    big = f > 1
    lo = np.where(big, mid, lo)
    hi = np.where(big, hi, mid)
d = (lo + hi) / 2
a = A0 + d
b = B0 + d
theta = np.arctan2(zs / b, xs / a)               # -pi..pi
speed = np.sqrt((a * np.sin(theta)) ** 2 + (b * np.cos(theta)) ** 2)
frac = ((theta % (2 * math.pi)) / (2 * math.pi) * NB)  # bay coordinate
bay = np.floor(frac).astype(int)
q = (frac - bay - 0.5) * (2 * math.pi / NB) * speed    # blocks from bay centre

MATS = {}
def mat(name, states=""):
    key = (name, states)
    if key not in MATS:
        MATS[key] = len(MATS) + 1
    return MATS[key]

AIR = 0
SAND = mat("sand"); SMOOTH = mat("smooth_sandstone"); CUT = mat("cut_sandstone")
CHISEL = mat("chiseled_sandstone"); SAND_BLOCK = mat("sandstone"); RED = mat("red_sandstone")
RSAND = mat("red_sand"); SBRICK = mat("stone_bricks"); CBRICK = mat("chiseled_stone_bricks")
PAND = mat("polished_andesite"); AND = mat("andesite"); QPIL = mat("quartz_pillar")
GOLD = mat("gold_block"); BARS = mat("iron_bars"); SMSTONE = mat("smooth_stone")
LANT_H = mat("lantern", '["hanging"=true]'); LANT = mat("lantern", '["hanging"=false]')
ENDROD = mat("end_rod", '["facing_direction"=1]'); QUARTZ = mat("quartz_block")
DIORITE = mat("polished_diorite"); REDC = mat("red_concrete"); WHITEC = mat("white_concrete")
DEEP = mat("polished_deepslate"); SEALAMP = mat("sea_lantern")

vox = np.zeros((H, D, W), dtype=np.int16)    # [y][z][x]
Y = np.arange(H)[:, None, None]
rel = Y + Y0 - 64                            # rel y of each layer (-1 = ground top)
dd = d[None]; qq = q[None]; bb = bay[None]

def put(mask, m):
    global vox
    vox = np.where(mask, m, vox)

ground = rel == -1

# --- arena floor and plaza (ground layer, y=62)
arena = ground & (dd < 0)
put(arena, SAND)
put(arena & (dd >= -1.5), SMOOTH)
put(arena & (dd >= -9.5) & (dd < -8.5), RSAND)
put(arena & (dd >= -16.5) & (dd < -15.5), RSAND)
put(arena & (dd >= -23.5) & (dd < -22.5), SMOOTH)
cx_ = (xs / A0) ** 2 + (zs / B0) ** 2
medal = ground & (cx_[None] < 0.045)
put(medal, RSAND)
put(ground & (cx_[None] < 0.012), GOLD)
cross = ground & (dd < -2) & ((np.abs(zs[None]) < 0.6) | (np.abs(xs[None]) < 0.6)) & (cx_[None] > 0.045)
put(cross, SAND_BLOCK)

plaza = ground & (dd >= 36) & (dd < 58)
put(plaza, PAND)
put(plaza & (dd < 38), SBRICK)
put(plaza & (dd >= 57), SBRICK)
put(plaza & (((dd >= 44) & (dd < 45)) | ((dd >= 52) & (dd < 53))), AND)
# checkerboard medallion rows between the bands
chk = (((np.floor(xs[None] / 2) + np.floor(zs[None] / 2)) % 2) == 0)
put(plaza & chk & (dd >= 46) & (dd < 51), DIORITE)
# ground ring under the structure itself
put(ground & (dd >= 0) & (dd < 36), SBRICK)

# gate avenues: lateral distance from the two axes
latx = np.abs(zs[None])     # for the +-x gates
latz = np.abs(xs[None])     # for the +-z gates
on_x_gate = np.abs(xs[None]) > A0 - 6
on_z_gate = np.abs(zs[None]) > B0 - 6
ave = ground & (dd >= 36) & (dd < 58) & (((latx <= 5) & on_x_gate & (np.abs(zs[None]) < 40)) |
                                           ((latz <= 5) & on_z_gate & (np.abs(xs[None]) < 40)))
put(ave, SBRICK)
put(ave & (((latx <= 0.6) & on_x_gate) | ((latz <= 0.6) & on_z_gate)), CBRICK)

# --- seating mass
def top_rel(dv):
    return 6 + np.floor((dv - 1) * 0.8)
mass = (dd >= 0) & (dd < 30) & (rel >= 0)
trow = top_rel(dd)
solid = mass & (rel <= np.where(dd < 1, 5, trow))
put(solid, SAND_BLOCK)
seat_top = mass & (dd >= 1) & (rel == trow)
tier1 = seat_top & (dd < 10)
tier2 = seat_top & (dd >= 10) & (dd < 20)
tier3 = seat_top & (dd >= 20)
put(tier1, RED); put(tier2, SMOOTH); put(tier3, CUT)
# tier dividers: raised wall one row on each diazoma
for d0 in (10, 20):
    put(mass & (dd >= d0) & (dd < d0 + 1) & (rel == trow + 1), CHISEL)
# podium wall and its safety fence
put(solid & (dd < 1) & (rel <= 4), CUT)
put(solid & (dd < 1) & (rel == 5), SMOOTH)
put((dd >= 0) & (dd < 1) & (rel >= 6) & (rel <= 8), BARS)
put((dd >= 0) & (dd < 1) & (rel == 9) & ((bb % 1) == 0) & (np.abs(qq) < 0.6), LANT)
# aisle lanes at every fourth bay boundary
lane = seat_top & (dd >= 1) & (((frac[None] % 4) < 0.09) | ((frac[None] % 4) > 3.91))
put(lane, PAND)
put((mass & (dd >= 3) & (rel == trow + 1) & (np.floor(dd) % 5 == 0)) &
    (((frac[None] % 4) < 0.09) | ((frac[None] % 4) > 3.91)) & (dd >= 1), LANT)

# --- gallery: three hollow storeys behind the outer wall
gal = (dd >= 30) & (dd < 33) & (rel >= 0) & (rel <= 29)
floors = gal & ((rel == 9) | (rel == 19) | (rel == 29))
put(floors, SMOOTH)
put((dd >= 30) & (dd < 33) & (rel == -1), SBRICK)
put((dd >= 30) & (dd < 31) & (rel >= 0) & (rel <= 28) & ~((rel == 9) | (rel == 19)), CUT)   # inner face of the gallery
# hang lanterns from each storey's ceiling
for r_ in (8, 18, 28):
    put((dd >= 31.2) & (dd < 32.4) & (rel == r_) & (np.abs(qq) < 0.55) & (bb % 2 == 0), LANT_H)

# --- outer wall d in [33,35), pilasters to 36, cornice, attic
wall = (dd >= 33) & (dd < 35) & (rel >= 0) & (rel <= 39)
pil = (dd >= 35) & (dd < 36) & (rel >= 0) & (rel <= 39) & (np.abs(qq) >= 2.4)
put(wall, CUT)
put(pil, SMOOTH)
put((wall | pil) & ((rel % 10) == 9), CHISEL)
put((wall | pil) & ((rel == 8) | (rel == 18) | (rel == 28)) & (dd >= 35), CHISEL)
put(wall & (rel <= 0), SBRICK)
put((dd >= 33) & (dd < 36) & (rel == -1), SBRICK)
# storey arches
u = rel % 10
storey = (rel >= 0) & (rel <= 29)
arch_vert = (u <= 5) & (np.abs(qq) <= 1.5)
arch_cap = (u > 5) & (qq ** 2 + (u - 5.0) ** 2 <= 1.5 ** 2 + 0.3)
opening = storey & (dd >= 32.9) & (dd < 36.1) & (arch_vert | arch_cap)
put(opening, AIR)
# attic windows (2 wide, 5 tall) and cornice
win = (dd >= 32.9) & (dd < 36.1) & (rel >= 32) & (rel <= 36) & (np.abs(qq) <= 1.0)
put(win, AIR)
put((wall | pil) & (rel >= 38) & (rel <= 39), CHISEL)
put((dd >= 33) & (dd < 37.5) & (rel == 40), SMOOTH)
put((dd >= 33) & (dd < 36.5) & (rel == 41) & (np.floor(frac[None] * 2) % 2 == 0) & (np.abs(qq) < 3.4), CUT)  # merlons
# banner masts and finials on every second pilaster
mast = (dd >= 35) & (dd < 36) & (np.abs(np.abs(qq) - (2 * math.pi / NB) * speed[None] / 2) < 0.7) & (bb % 2 == 0)
put(mast & (rel >= 41) & (rel <= 47), ENDROD)
put(mast & (rel == 48), GOLD)
# promenade parapet toward the arena
put((dd >= 29.9) & (dd < 30.5) & (rel == 30) & (rel <= 30) & (np.abs(qq) < 3.2), CUT)

# --- spawn pens under the stands: eight straight 3x3 gates, each a box the
# arena director opens with `fill ... air` and shuts with `fill ... iron_bars`
xw = np.arange(X0, X1 + 1)[None, None, :]
zw = np.arange(Z0, Z1 + 1)[None, :, None]
yw = np.arange(Y0, Y1 + 1)[:, None, None]

def box_mask(x0, y0, z0, x1, y1, z1):
    x0, x1, y0, y1, z0, z1 = min(x0, x1), max(x0, x1), min(y0, y1), max(y0, y1), min(z0, z1), max(z0, z1)
    return ((xw >= x0) & (xw <= x1) & (yw >= y0) & (yw <= y1) & (zw >= z0) & (zw <= z1))

pens = []
for k in range(8):
    th = math.radians(22.5 + 45 * k)
    px, pz = A0 * math.cos(th), B0 * math.sin(th)
    ax = "x" if abs(math.cos(th) / A0) >= abs(math.sin(th) / B0) else "z"
    sx = 1 if (math.cos(th) if ax == "x" else math.sin(th)) > 0 else -1
    if ax == "x":
        zc = CZ + int(round(pz))
        zi = zc - Z0
        edge = next(x for x in (range(CX, X1) if sx > 0 else range(CX, X0, -1)) if d[zi, x - X0] >= 0)
        gate = (edge, 64, zc - 1, edge, 66, zc + 1)
        room = (edge + sx, 64, zc - 1, edge + 4 * sx, 66, zc + 1)
        spawn = (edge + 2 * sx + 0.5, 64, zc + 0.5)
    else:
        xc = CX + int(round(px))
        xi = xc - X0
        edge = next(z for z in (range(CZ, Z1) if sx > 0 else range(CZ, Z0, -1)) if d[z - Z0, xi] >= 0)
        gate = (xc - 1, 64, edge, xc + 1, 66, edge)
        room = (xc - 1, 64, edge + sx, xc + 1, 66, edge + 4 * sx)
        spawn = (xc + 0.5, 64, edge + 2 * sx + 0.5)
    put(box_mask(*room), AIR)
    put(box_mask(room[0] - (0 if ax == "x" else 1), 63, room[2] - (1 if ax == "x" else 0),
                 room[3] + (0 if ax == "x" else 1), 63, room[5] + (1 if ax == "x" else 0)), SBRICK)
    put(box_mask(*gate), BARS)
    put(box_mask(room[0], 66, room[2], room[3], 66, room[5]) & (np.abs(spawn[0] - xw) + np.abs(spawn[2] - zw) < 1.6) & (yw == 66), LANT_H)
    pens.append({"id": k + 1, "angle_deg": round(22.5 + 45 * k), "spawn": {"x": int(math.floor(spawn[0])), "y": 64, "z": int(math.floor(spawn[2]))},
                 "gate": dict(zip(("x0", "y0", "z0", "x1", "y1", "z1"), gate)),
                 "open": "fill %d %d %d %d %d %d air" % gate})

# --- four grand gates: tunnels through everything
for axis in ("x", "z"):
    if axis == "x":
        lat = np.abs(zs[None]); along = np.abs(xs[None]); inside = along > A0 - 8
    else:
        lat = np.abs(xs[None]); along = np.abs(zs[None]); inside = along > B0 - 8
    tun = (((lat <= 4.5) & (rel >= 0) & (rel <= 7)) |
           ((lat ** 2 + (rel - 7.0) ** 2 <= 4.6 ** 2) & (rel > 7))) & inside & (dd < 40) & (dd > -12)
    # frame: pillars either side of the outer face, gold keystone above
    frame_pil = (lat >= 5) & (lat < 7) & (rel >= 0) & (rel <= 16) & inside & (dd >= 33) & (dd < 37)
    put(frame_pil, QPIL)
    put(frame_pil & ((rel == 16)), GOLD)
    lintel = (lat < 7) & (rel >= 13) & (rel <= 16) & inside & (dd >= 33) & (dd < 37) & (lat >= 0)
    put(lintel & ~tun, QUARTZ)
    put(lintel & (lat < 1.0) & (rel >= 14) & (rel <= 15), GOLD)
    put(tun, AIR)
    put(tun & (rel == -1), PAND)
    # tunnel floor and runner
    tf = (lat <= 4.5) & (rel == -1) & inside & (dd < 40) & (dd > -12)
    put(tf, PAND)
    put(tf & (lat <= 1.0), CBRICK)
    # vault lighting
    put(tun & (rel == 11) & (lat < 0.6) & (np.floor(along) % 6 == 0), LANT_H)
    # portcullis grille at the arena end
    grille = (lat <= 4.5) & (rel >= 0) & (rel <= 7) & inside & (dd >= 0) & (dd < 1)
    put(grille, BARS)
    if axis == "z":
        gm = grille & (zs[None] < 0)
        gc = np.argwhere(gm)
        gb = (int(X0 + gc[:, 2].min()), int(Y0 + gc[:, 0].min()), int(Z0 + gc[:, 1].min()),
              int(X0 + gc[:, 2].max()), int(Y0 + gc[:, 0].max()), int(Z0 + gc[:, 1].max()))
        put(box_mask(*gb), BARS)
        start_gate = gb

# --- plaza furniture: lamp posts, avenue colonnades
lamp_d = (dd >= 47.5) & (dd < 48.5) & (np.abs(qq) < 0.5)
lamp = lamp_d & (bb % 2 == 0) & (rel >= 0) & (rel <= 3)
put(lamp, QPIL)
put(lamp_d & (bb % 2 == 0) & (rel == 4), GOLD)
put(lamp_d & (bb % 2 == 0) & (rel == 5), LANT)
for axis in ("x", "z"):
    if axis == "x":
        lat = np.abs(zs[None]); along = np.abs(xs[None]); inside = along > A0 - 4
    else:
        lat = np.abs(xs[None]); along = np.abs(zs[None]); inside = along > B0 - 4
    col = (np.abs(lat - 6.5) < 0.6) & (dd >= 39) & (dd < 58) & (np.floor(dd) % 4 == 1) & inside
    put(col & (rel >= 0) & (rel <= 5), QPIL)
    put(col & (rel == 6), CHISEL)
    put(col & (rel == 7), LANT)

# --- sanity: keep everything inside the build box floor
vox[0] = np.where(vox[0] == 0, 0, vox[0])

# --- compress to boxes
LIMIT = 32000
cmds = []
def emit(m, x0, y0, z0, x1, y1, z1):
    name, states = [k for k, v in MATS.items() if v == m][0]
    # split by y so each fill stays under the limit
    vol = (x1 - x0 + 1) * (z1 - z0 + 1)
    step = max(1, LIMIT // vol)
    y = y0
    while y <= y1:
        ye = min(y1, y + step - 1)
        cmds.append(f"fill {x0} {y} {z0} {x1} {ye} {z1} {name} {states}".rstrip())
        y = ye + 1

src = vox
if "--against" in OPT:
    old = np.load(OPT["--against"])
    AIRB = mat("air")
    changed = vox != old
    src = np.where(changed & (vox == 0), AIRB, np.where(changed, vox, 0)).astype(np.int16)
if "--save" in OPT:
    np.save(OPT["--save"], vox)
rects = {}  # (m,x0,x1,z0,z1) -> y list
for yi in range(H):
    layer = src[yi]
    rows = {}
    for zi in range(D):
        row = layer[zi]
        if not row.any():
            continue
        change = np.nonzero(np.diff(row))[0] + 1
        starts = np.concatenate(([0], change)); ends = np.concatenate((change, [W])) - 1
        for s, e in zip(starts, ends):
            m = int(row[s])
            if m:
                rows.setdefault((m, int(s), int(e)), []).append(zi)
    for (m, s, e), zl in rows.items():
        zl.sort()
        run0 = prev = zl[0]
        for z in zl[1:] + [None]:
            if z is not None and z == prev + 1:
                prev = z; continue
            rects.setdefault((m, s, e, run0, prev), []).append(yi)
            if z is not None:
                run0 = prev = z
for (m, s, e, z0_, z1_), yl in rects.items():
    yl.sort()
    r0 = p = yl[0]
    for y in yl[1:] + [None]:
        if y is not None and y == p + 1:
            p = y; continue
        emit(m, X0 + s, Y0 + r0, Z0 + z0_, X0 + e, Y0 + p, Z0 + z1_)
        if y is not None:
            r0 = p = y

# bottom-up so sand lands on solid ground
def ykey(c):
    return int(c.split()[2])
cmds.sort(key=ykey)
open(os.path.join(OUT, "build.cmds"), "w").write("\n".join(cmds) + "\n")
print(len(cmds), "commands;", int((vox != 0).sum()), "solid voxels")

# --- layout in the arena director's schema (minecraft/crew/internal/arena/layout.go)
def chunk_area(x0, z0, x1, z1):
    return {"x0": x0 & ~15, "z0": z0 & ~15, "x1": x1 | 15, "z1": z1 | 15}

layout = {
    "center": {"x": CX, "y": 64, "z": CZ},
    "ground_y": 63,
    "floor_radius": B0 - 2,
    "outer_radius": A0 + 36,
    "areas": [chunk_area(CX - 64, CZ - 48, CX + 63, CZ + 47)],
    "pens": pens,
    "start_gate": {"name": "squad_start", "gate": dict(zip(("x0", "y0", "z0", "x1", "y1", "z1"), start_gate)),
                   "open": "fill %d %d %d %d %d %d air" % start_gate},
    "boss": {"x": CX, "y": 65, "z": CZ},
}
json.dump(layout, open(os.path.join(OUT, "arena.json"), "w"), indent=1)
print(len(pens), "pens; start gate", start_gate)


# --- invariant: with the gates shut no pen reaches the arena
def sealed(pen):
    sp = pen["spawn"]
    start = (sp["y"] - Y0, sp["z"] - Z0, sp["x"] - X0)
    seen, todo = {start}, [start]
    while todo:
        y, z, x = todo.pop()
        for dy, dz, dx in ((1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)):
            n = (y + dy, z + dz, x + dx)
            if not (0 <= n[0] < H and 0 <= n[1] < D and 0 <= n[2] < W) or n in seen or vox[n] != 0:
                continue
            seen.add(n)
            todo.append(n)
            if len(seen) > 200:
                return False
    return vox[start] == 0

leaks = [p["id"] for p in pens if not sealed(p)]
if leaks:
    sys.exit(f"pens {leaks} are not sealed: a mob could walk out with the gates shut")

# --- --feed=NAMESPACE/POD runs the commands on that lab server, 20 a second
if "--feed" in OPT:
    import subprocess, time
    ns, pod = OPT["--feed"].split("/", 1)
    ctr = os.environ.get("LAB_CONTAINER", "jdwillmsen-crew-lab-prd-minecraft-bedrock")
    script = 'while IFS= read -r c; do send-command "$c" >/dev/null 2>&1; sleep 0.045; done'
    for i in range(0, len(cmds), 1000):
        chunk = "\n".join(cmds[i:i + 1000]) + "\n"
        r = subprocess.run(["kubectl", "-n", ns, "exec", "-i", pod, "-c", ctr, "--", "sh", "-c", script],
                           input=chunk, text=True, capture_output=True)
        if r.returncode:
            sys.exit(f"feed failed after {i} commands: {r.stderr.strip()[:200]}")
        print(f"fed {min(i + 1000, len(cmds))}/{len(cmds)}", flush=True)
