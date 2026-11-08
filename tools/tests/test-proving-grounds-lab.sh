#!/usr/bin/env bash
# The laboratory generator must stay inside the server's limits: a fill over
# 32768 blocks is rejected whole, which silently leaves a section unbuilt.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
for section in all plaza wildlife safety arena supply breeding armor; do
  python3 "$here/tools/proving-grounds-lab.py" build "$section" | awk -v s="$section" '
    $1 == "fill" { n = ($5 - $2 + 1) * ($6 - $3 + 1) * ($7 - $4 + 1); if (n < 0) n = -n
      if (n > 32768) { print "FAIL: " s ": fill of " n " blocks: " $0; bad = 1 } }
    / hollow$/ { print "FAIL: " s ": hollow fill adds a floor and roof: " $0; bad = 1 }
    END { exit bad }'
done
python3 "$here/tools/proving-grounds-lab.py" clear | grep -q '^kill ' || { echo "FAIL: clear kills nothing"; exit 1; }
# The arena dome is sealed up to its open top: flood the air inside it and it must never get out below the hole.
python3 - "$here/tools/proving-grounds-lab.py" <<'PY' || { echo "FAIL: the arena dome leaks"; exit 1; }
import importlib.util, sys
from collections import deque
spec = importlib.util.spec_from_file_location("lab", sys.argv[1])
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)
r = lab.ARENA_R
solid = set()
for line in lab.dome(0, 0, r, 0):
    _, x1, y1, z1, x2, y2, z2, _b = line.split()
    for x in range(int(x1), int(x2) + 1):
        for y in range(int(y1), int(y2) + 1):
            for z in range(int(z1), int(z2) + 1):
                solid.add((x, y, z))
seen, queue = {(0, 0, 0)}, deque([(0, 0, 0)])
limit = r + 2
sealed_below = r - lab.DOME_OPEN
while queue:
    x, y, z = queue.popleft()
    for dx, dy, dz in ((1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)):
        n = (x + dx, y + dy, z + dz)
        if n in seen or n in solid or n[1] < 0:
            continue
        if n[1] >= sealed_below:
            # reached the open top: stop here, since air out there is free by design
            seen.add(n)
            continue
        if abs(n[0]) > limit or abs(n[2]) > limit:
            sys.exit(1)
        seen.add(n)
        queue.append(n)
assert len(seen) > 1000, len(seen)
assert any(y >= sealed_below for _, y, _ in seen), "the dome has no open top"
PY
# Roofs are open on purpose (fly in): no pen, cage or yard stall may carry a glass lid.
for section in wildlife safety breeding armor; do
  python3 "$here/tools/proving-grounds-lab.py" build "$section" | awk -v s="$section" '
    $1 == "fill" && $3 == $6 && $8 == "glass" && ($5 - $2) > 3 && ($7 - $4) > 3 { print "FAIL: " s ": glass lid: " $0; bad = 1 }
    END { exit bad }'
done
# every chest fits its 27 slots
python3 "$here/tools/proving-grounds-lab.py" build all | awk '$1 == "replaceitem" && $7 > 26 { print "FAIL: slot " $7 " is outside a chest: " $0; bad = 1 } END { exit bad }'
echo "PASS: proving-grounds laboratory generator"
