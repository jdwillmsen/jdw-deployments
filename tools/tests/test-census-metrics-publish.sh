#!/usr/bin/env bash
# Exercises the census metrics sidecar against staged payload states.
#
# The sidecar writes a ConfigMap, so it is tested rather than reasoned about.
# The shim below records the apply instead of performing it, which means these
# cases run anywhere.
#
# The script is extracted from the rendered chart rather than copied here, so
# the test cannot drift away from what actually ships.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template minecraft-fwb "$here/charts/minecraft-fwb" \
  -f "$here/charts/minecraft-fwb/values.yaml" \
  --set census.enabled=true --set census.metrics.enabled=true \
  | python3 -c "
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get('kind') == 'CronJob' and doc['metadata']['name'].endswith('-census'):
        for c in doc['spec']['jobTemplate']['spec']['template']['spec']['initContainers']:
            if c['name'] == 'metrics-publish':
                print(c['args'][0])
" > "$work/publish.sh"
[ -s "$work/publish.sh" ] || fail "could not extract the publisher script from the chart"

mkdir -p "$work/sa"
echo -n "test-ns" > "$work/sa/namespace"
sed -i "s|/var/run/secrets/kubernetes.io/serviceaccount/namespace|$work/sa/namespace|" "$work/publish.sh"

mkdir -p "$work/bin"
cat > "$work/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
# `create ... --dry-run=client` feeds `apply -f -`, so the apply is the end of
# the pipeline and the one worth recording.
if [[ "$1" == "apply" ]]; then
  cat > /dev/null
  echo "__APPLIED__" >> "$STATE_DIR/calls"
  exit 0
fi
if [[ "$1" == "create" ]]; then
  echo "apiVersion: v1"
  exit 0
fi
exit 0
SHIM
chmod +x "$work/bin/kubectl"

# Runs the publisher in the background and returns its PID, so a case can stage
# the payload before or after it starts and can terminate it the way the
# kubelet does.
start() {
  PATH="$work/bin:$PATH" STATE_DIR="$work/state" \
    METRICS_CM=census-metrics METRICS_FILE="$work/state/metrics.txt" \
    bash "$work/publish.sh" > "$work/state/log" 2>&1 &
  echo $!
}

reset() { rm -rf "$work/state"; mkdir -p "$work/state"; }

# `start` backgrounds the publisher inside a command substitution, so it is not
# this shell's child and `wait` cannot be used on it. Polling for the process
# to go is the portable form, and it has to be a poll rather than an assumption
# either way: bash defers a trap until the foreground `sleep` returns, so the
# shutdown publish lands up to one poll interval after the signal.
stop() {
  kill -TERM "$1" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.2
  done
  fail "publisher did not exit after SIGTERM"
}

applied() { grep -qs "__APPLIED__" "$work/state/calls"; }

# Waits rather than sleeping a fixed time: the loop polls every 2s, and a
# fixed sleep long enough to be safe makes the suite slow for no benefit.
wait_for_publish() {
  for _ in $(seq 1 50); do
    applied && return 0
    sleep 0.2
  done
  return 1
}

# The ordinary night: the census writes its payload, the sidecar publishes it.
reset
printf 'mc_census_entities{dimension="overworld"} 24711\n' > "$work/state/metrics.txt"
pid="$(start)"
wait_for_publish || fail "payload present and never published"
stop "$pid"
echo "  ok: publishes a payload the census wrote"

# The payload lands while the sidecar is already running, which is the real
# ordering: the census writes it seconds before it exits.
reset
pid="$(start)"
sleep 0.5
printf 'mc_census_entities{dimension="overworld"} 24711\n' > "$work/state/metrics.txt"
wait_for_publish || fail "payload written after start was never published"
stop "$pid"
echo "  ok: publishes a payload that appears after it starts"

# The race this exists for. The kubelet terminates the sidecar as soon as the
# census exits, which is immediately after the payload is written -- so a
# publisher that only polls would miss a file that lands inside its last
# interval.
reset
pid="$(start)"
# Settles first, because a signal delivered before bash has installed the trap
# is a property of this harness rather than of the sidecar, which has been
# running since before the census container started.
sleep 0.5
printf 'mc_census_entities{dimension="overworld"} 24711\n' > "$work/state/metrics.txt"
stop "$pid"
applied || fail "a payload written just before SIGTERM was never published"
echo "  ok: publishes on the way out"

# A census that failed writes no payload. Publishing an empty ConfigMap would
# replace last night's counts with nothing, which reads as a world that lost
# its mobs.
reset
pid="$(start)"
sleep 0.5
stop "$pid"
applied && fail "published something with no payload on disk"
grep -qs "skipped" "$work/state/log" || fail "shutdown with no payload said nothing about it"
echo "  ok: publishes nothing when the census produced nothing"

echo "PASS"
