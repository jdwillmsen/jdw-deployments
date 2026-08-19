#!/usr/bin/env bash
# Exercises what the backup exporter actually publishes, for both of the two
# payloads it can serve.
#
# The distinction under test is the one the rules downstream depend on: a
# producer that has written state, and a producer that has not. Both serve a
# timestamp and a size of zero in the never-written case, so the only thing
# separating "measured as empty" from "never measured" is the gauge asserted
# here. A backup that ran and wrote nothing must stay a critical page; a
# backup nobody has measured yet must not. Read from the rendered chart rather
# than restated, so the test cannot drift from what ships.
#
# httpd and the archive volume are both stubbed away. The subject is the
# refresh loop that builds the payload, not the web server that serves it.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'pkill -f "$work/exporter.sh" 2>/dev/null || true; rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template minecraft-fwb "$here/charts/minecraft-fwb" \
  -f "$here/charts/minecraft-fwb/values.yaml" \
  | python3 -c "
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get('kind') == 'Deployment' and 'backup-exporter' in doc['metadata']['name']:
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
  env PATH="$work/bin:$PATH" \
      BACKUP_JOB="${BACKUP_JOB:-fwb-prd-backup}" \
      MAX_AGE_SECONDS="${MAX_AGE_SECONDS:-172800}" \
      REFRESH_SECONDS=300 PORT=9100 \
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

# A payload nothing has written to. Both contract gauges read zero -- kept
# deliberately, so a backup deployed and never run does not look healthy -- and
# the state gauge is what says those zeros were never measured.
rm -f "$state/metrics.txt"
run_exporter
body="$(published)" || fail "unreported state: nothing was published"
[[ "$body" == *'backup_state_reported{backup_job="fwb-prd-backup",artifact="world"} 0'* ]] \
  || fail "unreported state: expected backup_state_reported 0, got:"$'\n'"$body"
[[ "$body" == *'backup_last_success_timestamp_seconds{backup_job="fwb-prd-backup",artifact="world"} 0'* ]] \
  || fail "unreported state: the placeholder zeros must stay"
[[ "$body" == *'backup_last_artifact_bytes{backup_job="fwb-prd-backup",artifact="world"} 0'* ]] \
  || fail "unreported state: the placeholder zeros must stay"
[[ "$body" == *'backup_max_age_seconds{backup_job="fwb-prd-backup",artifact="world"} 172800'* ]] \
  || fail "unreported state: the producer's own budget must be published"
started="$(printf '%s\n' "$body" | sed -n 's/^backup_exporter_start_time_seconds{[^}]*} //p')"
[[ "$started" =~ ^[0-9]+$ ]] || fail "unreported state: start time is not a number: '$started'"
[ "$started" -gt 1700000000 ] || fail "unreported state: start time '$started' is not a plausible clock reading"
echo "  ok: a producer that has never reported publishes zeros and says they are placeholders"

# The same zeros, this time measured. Identical contract gauges, opposite
# meaning -- and the only difference on the wire is the state gauge. This is
# the case that must stay a critical page.
cat > "$state/metrics.txt" <<'STATE'
backup_last_success_timestamp_seconds{backup_job="fwb-prd-backup",artifact="world"} 1000000000
backup_last_artifact_bytes{backup_job="fwb-prd-backup",artifact="world"} 0
backup_max_age_seconds{backup_job="fwb-prd-backup",artifact="world"} 172800
STATE
run_exporter
body="$(published)" || fail "reported empty artifact: nothing was published"
[[ "$body" == *'backup_state_reported{backup_job="fwb-prd-backup",artifact="world"} 1'* ]] \
  || fail "reported empty artifact: expected backup_state_reported 1, got:"$'\n'"$body"
[[ "$body" == *'backup_last_artifact_bytes{backup_job="fwb-prd-backup",artifact="world"} 0'* ]] \
  || fail "reported empty artifact: the producer's own reading must be served verbatim"
echo "  ok: a measured zero-byte artifact is served as reported, not as a placeholder"

# An empty state file is not state. The mount resolves empty whenever the
# ConfigMap is absent, which is what turned "missing" into "zero" silently in
# the first place, so the fallback has to label itself the same way.
: > "$state/metrics.txt"
run_exporter
body="$(published)" || fail "empty state file: nothing was published"
[[ "$body" == *'backup_state_reported{backup_job="fwb-prd-backup",artifact="world"} 0'* ]] \
  || fail "empty state file: an unwritten mount must publish 0, got:"$'\n'"$body"
echo "  ok: an empty state mount is unreported state, not a reading of zero"

# The publish gate. A source read that dies partway leaves bytes behind, and a
# payload carrying the contract gauges but not the state gauge would read
# downstream as a producer that never adopted it -- restoring the ambiguity
# this whole change removes. Nothing may be published unless the state gauge
# made it in.
cat > "$state/metrics.txt" <<'STATE'
backup_last_success_timestamp_seconds{backup_job="fwb-prd-backup",artifact="world"} 1000000000
STATE
cat > "$work/bin/cat" <<'SHIM'
#!/usr/bin/env bash
head -c 40 "$1"
exit 1
SHIM
chmod +x "$work/bin/cat"
run_exporter
[ -f "$out/metrics.txt" ] && fail "truncated read: a payload with no state gauge was published:"$'\n'"$(cat "$out/metrics.txt")"
echo "  ok: a payload whose state gauge is missing is never published"
rm -f "$work/bin/cat"

# The startup guard, which the state gauge now sits behind: a budget that
# cannot be formatted would reject the whole scrape, so the pod refuses to
# start instead of serving a payload Prometheus will drop.
MAX_AGE_SECONDS="not-a-number" run_exporter
[ -f "$out/metrics.txt" ] && fail "bad budget: the exporter published instead of refusing to start"
grep -q "FATAL: MAX_AGE_SECONDS" "$work/last-stderr" || fail "bad budget: expected a fatal error, got:"$'\n'"$(cat "$work/last-stderr")"
echo "  ok: an unformattable budget stops the exporter rather than poisoning the scrape"

echo "all backup exporter cases passed"
