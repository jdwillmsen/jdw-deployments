#!/usr/bin/env bash
# Generates the lab Colosseum and checks the layout the arena director reads:
# eight pens with straight 3x3 gate boxes, a start gate, and a build that
# stays inside the area the ticking areas load. The generator itself refuses a
# build whose pens are not sealed, so a zero exit also covers that.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

python3 -c 'import numpy' 2>/dev/null || { echo "SKIP: numpy is not installed"; exit 0; }

python3 "$here/tools/crew-lab-colosseum.py" "$work" >/dev/null || fail "generator failed"

python3 - "$work" <<'PY' || fail "the layout is not what the arena director needs"
import json, re, sys

work = sys.argv[1]
layout = json.load(open(f"{work}/arena.json"))
assert len(layout["pens"]) == 8, len(layout["pens"])
for p in layout["pens"]:
    g = p["gate"]
    dims = sorted([g["x1"] - g["x0"] + 1, g["z1"] - g["z0"] + 1])
    assert dims == [1, 3], f"pen {p['id']} gate is not a flat 3-wide plane: {g}"
    assert g["y1"] - g["y0"] + 1 == 3, f"pen {p['id']} gate is not 3 high"
    assert p["open"].endswith(" air"), p["open"]
assert layout["start_gate"]["open"].endswith(" air")
assert layout["boss"]["y"] > 0 and layout["ground_y"] == 63

for line in open(f"{work}/build.cmds"):
    m = re.match(r"fill (-?\d+) (\d+) (-?\d+) (-?\d+) (\d+) (-?\d+) ", line)
    assert m, line
    x0, y0, z0, x1, y1, z1 = map(int, m.groups())
    assert -112 <= x0 <= x1 <= 111 and -860 <= z0 <= z1 <= -637 and 63 <= y0 <= y1 <= 113, line
    assert (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1) <= 32768, line
PY
echo "ok"
