#!/usr/bin/env bash
# Exercises the nightly restart CronJob's decision logic against staged states.
#
# The script under test stops production, so it is tested rather than reasoned
# about. The shim below answers every read from staged values and records the
# stop instead of delivering it, so the cases can run anywhere without being
# able to disconnect anyone.
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
  --set scheduledRestart.enabled=true \
  | python3 -c "
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get('kind') == 'CronJob' and 'scheduled-restart' in doc['metadata']['name']:
        print(doc['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]['args'][0])
" > "$work/restart.sh"
[ -s "$work/restart.sh" ] || fail "could not extract the restart script from the chart"

mkdir -p "$work/sa"
echo -n "test-ns" > "$work/sa/namespace"
sed -i "s|/var/run/secrets/kubernetes.io/serviceaccount/namespace|$work/sa/namespace|" "$work/restart.sh"

mkdir -p "$work/bin"
cat > "$work/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
# Pod state is answered from FAKE_STATE until a stop has been recorded and
# FAKE_STATE_AFTER from then on, which is how a case stages what the restart
# poll sees without the test having to time anything.
if [[ "$1" == "exec" ]]; then
  # Recorded to files rather than printed, because every exec the script makes
  # is redirected to /dev/null -- the announcements deliberately so, since a
  # failed one must never fail the run.
  if [[ "$*" == *"send-command stop"* ]]; then
    echo "__STOP_CALLED__" >> "$STATE_DIR/calls"
    [[ "${FAKE_STOP_OK:-yes}" == "no" ]] && exit 2
    touch "$STATE_DIR/stopped"
    exit 0
  fi
  [[ "$*" == *"tellraw"* ]] && { echo "__TELLRAW__ $*" >> "$STATE_DIR/calls"; exit 0; }
  exit 0
fi
if [[ "$1" == "get" ]]; then
  [[ "${FAKE_EXISTS:-yes}" == "no" ]] && exit 1
  [[ "$*" == *".ready"* ]] && { printf '%s' "${FAKE_READY:-true}"; exit 0; }
  if [[ "$*" == *"restartCount"* ]]; then
    # Unset falls back to a default; set-but-empty stays empty, which is how a
    # case stages a read that failed rather than one that answered.
    if [[ -f "$STATE_DIR/stopped" ]]; then
      printf '%s' "${FAKE_STATE_AFTER-uid-1 4}"
    else
      printf '%s' "${FAKE_STATE-uid-1 3}"
    fi
    exit 0
  fi
  exit 0
fi
[[ "$1" == "logs" ]] && { printf '%s\n' "${FAKE_LOGS:-There are 0/20 players online:}"; exit 0; }
exit 0
SHIM
chmod +x "$work/bin/kubectl"

# LEAD_SECONDS=1 keeps the countdown out of the runtime while still walking the
# announcement path -- the milestone loop skips every milestone above the lead,
# which is the same branch a real 120s run takes for the ones it has passed.
#
# Bounded, because the failure that would hurt most here is a hang: the restart
# poll waits two minutes for a state change that a wedged case never produces,
# and the suite must report that rather than sit on it.
run() {
  local out
  out="$(timeout 200 env PATH="$work/bin:$PATH" STATE_DIR="$work/state" \
      SERVER_POD=server-0 SERVER_CONTAINER=server LEAD_SECONDS=1 \
      "$@" bash "$work/restart.sh" 2>&1)" || true
  # The recorded exec calls are part of what a case asserts on, so they are
  # folded into the output the assertions match against.
  printf '%s\n%s' "$out" "$(cat "$work/state/calls" 2>/dev/null || true)"
}

reset() { rm -rf "$work/state"; mkdir -p "$work/state"; }

assert_contains() {
  local name="$1" needle="$2" out; shift 2
  reset
  out="$(run "$@")"
  [[ "$out" == *"$needle"* ]] || fail "$name: expected '$needle' in output, got: $out"
  echo "  ok: $name"
}

assert_missing() {
  local name="$1" needle="$2" out; shift 2
  reset
  out="$(run "$@")"
  [[ "$out" != *"$needle"* ]] || fail "$name: '$needle' appeared and must not have"
  echo "  ok: $name"
}

# The ordinary night. Nobody is on, so nothing is announced and the server is
# stopped straight away.
assert_contains "empty server restarts in place" '"event":"restarted"' \
  FAKE_LOGS="There are 0/20 players online:"
assert_missing "empty server announces nothing" "__TELLRAW__" \
  FAKE_LOGS="There are 0/20 players online:"

# Players online are warned first. The tellraw payload is checked for its JSON
# envelope because the encoding is the part that has broken before: an
# interpolated message with a quote in it produces rawtext the server rejects
# and no warning is delivered.
assert_contains "players online are warned" '__TELLRAW__' \
  FAKE_LOGS="There are 3/20 players online: a, b, c"
assert_contains "warning is encoded as rawtext" '{"rawtext":' \
  FAKE_LOGS="There are 3/20 players online: a, b, c"

# An unreadable count is not evidence of an empty server, and the two mistakes
# do not cost the same: a countdown nobody reads costs two minutes, a silent
# disconnect costs whatever someone was standing in.
assert_contains "unreadable player count still announces" '__TELLRAW__' \
  FAKE_LOGS="nothing that parses"

# Both skips must leave the server alone, and neither is a failure: the version
# check restarts this server too, and a run that lands while the container is
# coming back should stand down rather than stack a second stop on it.
assert_missing "absent pod is not stopped" "__STOP_CALLED__" FAKE_EXISTS=no
assert_contains "absent pod skips cleanly" '"event":"skipped"' FAKE_EXISTS=no
assert_missing "unready pod is not stopped" "__STOP_CALLED__" FAKE_READY=false
assert_contains "unready pod skips cleanly" '"event":"skipped"' FAKE_READY=false

# send-command exits 2 when the write never reached the server process. A stop
# that was not delivered has to fail the run rather than fall through to a poll
# that cannot succeed.
assert_contains "undelivered stop fails the run" '"event":"failed"' \
  FAKE_STOP_OK=no

# The regression this case exists for: an unreadable baseline used to make the
# first poll reading differ from it, so a restart that went perfectly was
# reported as a pod recreation -- the data-loss alarm -- and the run failed.
# Now the state is read before the stop is sent, and an empty answer stops the
# run while the server is still up.
assert_missing "unreadable state does not stop the server" "__STOP_CALLED__" \
  FAKE_STATE= FAKE_STATE_AFTER=
assert_contains "unreadable state fails the run" '"event":"failed"' \
  FAKE_STATE= FAKE_STATE_AFTER=

# A new pod UID means the world volume was unmounted and re-placed, which is
# the outcome that cost 11 .ldb files in August. It cannot be prevented by the
# time it is visible, so it is made loud instead of being reported as success.
assert_contains "pod recreation is reported as a failure" "pod was recreated" \
  FAKE_STATE="uid-1 3" FAKE_STATE_AFTER="uid-2 0"

# An in-place restart is the counterpart: same UID, higher count, reported as
# the success it is.
assert_contains "same uid with a higher count is a success" "restartCount 3 -> 4" \
  FAKE_STATE="uid-1 3" FAKE_STATE_AFTER="uid-1 4"

# The stop landed and the container never came back. Takes the full two-minute
# poll, which is why this case is last.
assert_contains "a stop that never restarts fails" "never restarted" \
  FAKE_STATE="uid-1 3" FAKE_STATE_AFTER="uid-1 3"

echo "PASS"
