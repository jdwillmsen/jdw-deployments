#!/usr/bin/env bash
# Exercises what the census exporter publishes, for both payloads it can serve.
#
# The distinction under test is the one the rules depend on: a census that has
# published counts, and one that has not. The ConfigMap mount resolves to an
# empty directory when nothing has ever been written, so without the reported
# gauge "no census yet" and "a world with nothing in it" arrive as the same
# empty answer. Read from the rendered chart rather than restated, so the test
# cannot drift from what ships.
#
# httpd is stubbed away. The subject is the refresh loop that builds the
# payload, not the web server that serves it.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'pkill -f "$work/exporter.sh" 2>/dev/null || true; rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template minecraft-fwb "$here/charts/minecraft-fwb" \
  -f "$here/charts/minecraft-fwb/values.yaml" \
  --set census.enabled=true --set census.metrics.enabled=true \
  | python3 -c "
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get('kind') == 'Deployment' and 'census-exporter' in doc['metadata']['name']:
        print(doc['spec']['template']['spec']['containers'][0]['args'][0])
" > "$work/exporter.sh"
[ -s "$work/exporter.sh" ] || fail "could not extract the exporter script from the chart"

out="$work/out"
state="$work/state"
mkdir -p "$state" "$work/bin"
sed -i "s|^OUT=/run/metrics$|OUT=$out|; s|^SRC=/run/state/metrics.txt$|SRC=$state/metrics.txt|" "$work/exporter.sh"
grep -q "^OUT=$out\$" "$work/exporter.sh" || fail "could not redirect the exporter's output path"
grep -q "^SRC=$state/metrics.txt\$" "$work/exporter.sh" || fail "could not redirect the exporter's state path"

# The script ends in `exec httpd`, so the stub is what keeps the process alive
# while the refresh loop beside it writes the first payload.
cat > "$work/bin/httpd" <<'SHIM'
#!/usr/bin/env bash
sleep 60
SHIM
chmod +x "$work/bin/httpd"

# One pass is all any case needs: the loop writes before it first sleeps.
run_exporter() {
  local runner i=0
  rm -f "$out/metrics.txt" "$out/.metrics.tmp"
  env PATH="$work/bin:$PATH" REFRESH_SECONDS=300 PORT=9102 \
      bash "$work/exporter.sh" >"$work/last-stderr" 2>&1 &
  runner=$!
  while [ "$i" -lt 60 ]; do
    [ -f "$out/metrics.txt" ] && break
    kill -0 "$runner" 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
  done
  kill "$runner" 2>/dev/null || true
  pkill -f "$work/exporter.sh" 2>/dev/null || true
  wait "$runner" 2>/dev/null || true
}

published() { [ -f "$out/metrics.txt" ] && cat "$out/metrics.txt"; }

# Nothing has ever been published. The exporter has to say so itself: the
# never-reported alert fires on this gauge, and there is no census payload here
# to carry any other signal.
rm -f "$state/metrics.txt"
run_exporter
body="$(published)" || fail "unreported state: nothing was published"
[[ "$body" == *'mc_census_reported 0'* ]] \
  || fail "unreported state: expected mc_census_reported 0, got:"$'\n'"$body"
started="$(printf '%s\n' "$body" | sed -n 's/^mc_census_exporter_start_time_seconds //p')"
[[ "$started" =~ ^[0-9]+$ ]] || fail "unreported state: start time is not a number: '$started'"
[ "$started" -gt 1700000000 ] || fail "unreported state: start time '$started' is not a plausible clock reading"
echo "  ok: a census that has never reported publishes 0 and its own start time"

# A real payload is served through unchanged. The counts are the census's
# words, not this container's, and an exporter that reformatted them would be
# a second place for the numbers to disagree.
cat > "$state/metrics.txt" <<'STATE'
# HELP mc_census_entities Entities stored in the world, by dimension.
# TYPE mc_census_entities gauge
mc_census_entities{dimension="overworld"} 24711
STATE
run_exporter
body="$(published)" || fail "reported state: nothing was published"
[[ "$body" == *'mc_census_entities{dimension="overworld"} 24711'* ]] \
  || fail "reported state: the census payload must be served verbatim, got:"$'\n'"$body"
[[ "$body" == *'mc_census_reported 1'* ]] \
  || fail "reported state: expected mc_census_reported 1, got:"$'\n'"$body"
echo "  ok: a published payload is served verbatim and marked as reported"

# An empty state file is not state. The mount resolves empty whenever the
# ConfigMap is absent, which is the case the reported gauge exists to name.
: > "$state/metrics.txt"
run_exporter
body="$(published)" || fail "empty state file: nothing was published"
[[ "$body" == *'mc_census_reported 0'* ]] \
  || fail "empty state file: an unwritten mount must publish 0, got:"$'\n'"$body"
echo "  ok: an empty state mount is unreported, not a census reporting nothing"

# The publish gate. A source read that dies partway leaves bytes behind, and a
# payload carrying counts but not the reported gauge reads downstream as an
# exporter too old to publish it. Nothing may be published unless the gauge
# made it in.
cat > "$state/metrics.txt" <<'STATE'
mc_census_entities{dimension="overworld"} 24711
STATE
cat > "$work/bin/cat" <<'SHIM'
#!/usr/bin/env bash
head -c 20 "$1"
exit 1
SHIM
chmod +x "$work/bin/cat"
run_exporter
if [ -f "$out/metrics.txt" ]; then
  fail "a truncated read was published:"$'\n'"$(published)"
fi
rm -f "$work/bin/cat"
echo "  ok: a truncated read publishes nothing rather than a payload missing its gauge"

echo "PASS"
