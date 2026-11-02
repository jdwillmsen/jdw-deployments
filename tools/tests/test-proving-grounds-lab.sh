#!/usr/bin/env bash
# The laboratory generator must stay inside the server's limits: a fill over
# 32768 blocks is rejected whole, which silently leaves a section unbuilt.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
for section in all plaza wildlife safety arena supply; do
  python3 "$here/tools/proving-grounds-lab.py" build "$section" | awk -v s="$section" '
    $1 == "fill" { n = ($5 - $2 + 1) * ($6 - $3 + 1) * ($7 - $4 + 1); if (n < 0) n = -n
      if (n > 32768) { print "FAIL: " s ": fill of " n " blocks: " $0; bad = 1 } }
    / hollow$/ { print "FAIL: " s ": hollow fill adds a floor and roof: " $0; bad = 1 }
    END { exit bad }'
done
python3 "$here/tools/proving-grounds-lab.py" clear | grep -q '^kill ' || { echo "FAIL: clear kills nothing"; exit 1; }
echo "PASS: proving-grounds laboratory generator"
