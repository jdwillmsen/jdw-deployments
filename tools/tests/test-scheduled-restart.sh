#!/usr/bin/env bash
# Exercises the scheduled-restart CronJob's decision logic against staged pod
# states.
#
# The script under test stops a live Minecraft server, so it is tested rather
# than reasoned about. The shim below forwards nothing to a real cluster: it
# stages pod state, records every console command, and lets each case assert
# both what the job did and what it refused to do.
#
# The case that matters most is the pod-recreated one. Restarting in place keeps
# the world volume mounted; recreating the pod migrates it, which is what cost
# 11 .ldb files on 2026-08-30. The job asserts the pod UID did not move, and
# that assertion is only worth anything if something checks it holds.
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

# Instant sleeps, so a 120-second countdown does not cost the suite two minutes.
# The restart-wait loop is bounded by bash's SECONDS rather than by iteration
# count, so every case below is staged to resolve on the loop's first pass --
# the timeout paths would cost their real wall-clock budget to reach and are
# covered by READY_TIMEOUT=0 instead.
cat > "$work/bin/sleep" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM

cat > "$work/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
# Marker written once the stop lands, so the staged pod state can differ
# before and after it without the shim keeping state in memory.
STOPPED="$FAKE_WORK/stopped"

if [[ "$1" == "get" ]]; then
  [[ "${FAKE_EXISTS:-yes}" == "no" ]] && exit 1
  if [[ "$*" == *"metadata.uid"* ]]; then
    if [[ -f "$STOPPED" ]]; then
      printf '%s %s' "${FAKE_AFTER_UID:-uid-a}" "${FAKE_AFTER_RESTARTS:-1}"
    else
      printf '%s %s' "uid-a" "0"
    fi
    exit 0
  fi
  if [[ "$*" == *"ready"* ]]; then
    if [[ -f "$STOPPED" ]]; then
      printf '%s' "${FAKE_READY_AFTER:-true}"
    else
      printf '%s' "${FAKE_READY:-true}"
    fi
    exit 0
  fi
  exit 0
fi

if [[ "$1" == "exec" ]]; then
  if [[ "$*" == *"send-command stop"* ]]; then
    [[ "${FAKE_STOP_OK:-yes}" == "no" ]] && exit 1
    echo "stopped" > "$STOPPED"
    echo "__STOP__" >> "$FAKE_WORK/console"
    exit 0
  fi
  if [[ "$*" == *"tellraw"* ]]; then
    echo "__TELLRAW__" >> "$FAKE_WORK/console"
    exit 0
  fi
  if [[ "$*" == *"send-command list"* ]]; then
    echo "__LIST__" >> "$FAKE_WORK/console"
    exit 0
  fi
  exit 0
fi

if [[ "$1" == "logs" ]]; then
  printf '%s\n' "${FAKE_LOGS:-}"
  exit 0
fi
exit 0
SHIM

chmod +x "$work/bin/kubectl" "$work/bin/sleep"

run_case() {
  rm -f "$work/console" "$work/stopped"
  FAKE_WORK="$work" PATH="$work/bin:$PATH" \
    SERVER_POD=server-0 SERVER_CONTAINER=server \
    LEAD_SECONDS="${LEAD_SECONDS:-120}" READY_TIMEOUT="${READY_TIMEOUT:-300}" \
    bash "$work/restart.sh" 2>&1
}

console_has() { grep -qF "$1" "$work/console" 2>/dev/null; }

# --- the server is not there at all ------------------------------------------
out="$(FAKE_EXISTS=no run_case)" || fail "absent server should exit 0, not fail the run"
[[ "$out" == *'"event":"skipped"'* ]] || fail "absent server should emit skipped, got: $out"
console_has "__STOP__" && fail "absent server: a stop was delivered anyway"

# --- the server is present but not Ready --------------------------------------
# volume-recovery owns the wedged case; stopping it here races that actor.
out="$(FAKE_READY=false run_case)" || fail "not-ready server should exit 0"
[[ "$out" == *'"event":"skipped"'* ]] || fail "not-ready server should emit skipped, got: $out"
console_has "__STOP__" && fail "not-ready server: a stop was delivered anyway"

# --- nobody online: restart, but do not announce to an empty world ------------
out="$(FAKE_LOGS='There are 0/20 players online' run_case)" || fail "empty server restart should succeed: $out"
[[ "$out" == *'"event":"proceeding"'* ]] || fail "empty server should skip the countdown, got: $out"
console_has "__TELLRAW__" && fail "empty server: announced a countdown to nobody"
console_has "__STOP__" || fail "empty server: never delivered the stop"
[[ "$out" == *'"event":"done"'* ]] || fail "empty server should finish done, got: $out"

# --- players online: full countdown before the stop ---------------------------
out="$(FAKE_LOGS='There are 4/20 players online' run_case)" || fail "populated restart should succeed: $out"
[[ "$out" == *'"event":"announcing"'* ]] || fail "populated server should announce, got: $out"
console_has "__TELLRAW__" || fail "populated server: no countdown was sent"
# Two opening lines, three milestones (60/30/10), one final notice.
tellraws="$(grep -cF "__TELLRAW__" "$work/console")"
[ "$tellraws" -eq 6 ] || fail "expected 6 countdown messages, got $tellraws"
# Ordering is the whole point of a countdown: the stop must come after every
# message, not before or among them.
[ "$(tail -1 "$work/console")" = "__STOP__" ] \
  || fail "the stop was not the last console action; players were warned too late"
[ "$(grep -n "__STOP__" "$work/console" | cut -d: -f1)" -gt "$(grep -n "__TELLRAW__" "$work/console" | tail -1 | cut -d: -f1)" ] \
  || fail "a countdown message was sent after the stop"

# --- an unreadable player count must not silence the countdown ----------------
out="$(FAKE_LOGS='garbage that is not a player count' run_case)" || fail "unknown count should still restart: $out"
[[ "$out" == *'"event":"unknown"'* ]] || fail "unreadable count should emit unknown, got: $out"
console_has "__TELLRAW__" || fail "unreadable count: skipped the countdown rather than assuming players"

# --- the stop never reaches the server ----------------------------------------
out="$(FAKE_LOGS='There are 0/20 players online' FAKE_STOP_OK=no run_case)" \
  && fail "an undelivered stop must fail the run"
[[ "$out" == *'"event":"failed"'* ]] || fail "undelivered stop should emit failed, got: $out"

# --- the pod was recreated rather than restarted in place ---------------------
# The world volume moved. This must fail loudly even though the server is up.
out="$(FAKE_LOGS='There are 0/20 players online' FAKE_AFTER_UID=uid-b FAKE_AFTER_RESTARTS=0 run_case)" \
  && fail "a recreated pod must fail the run"
[[ "$out" == *'"event":"failed"'* ]] || fail "recreated pod should emit failed, got: $out"
[[ "$out" == *"uid-a -> uid-b"* ]] || fail "failure should name both UIDs, got: $out"

# --- the server restarted but never became Ready ------------------------------
out="$(READY_TIMEOUT=0 FAKE_LOGS='There are 0/20 players online' FAKE_READY_AFTER=false run_case)" \
  && fail "a server that never came back Ready must fail the run"
[[ "$out" == *'"event":"failed"'* ]] || fail "never-ready server should emit failed, got: $out"

echo "PASS: scheduled restart announces before stopping, refuses to act on a sick server, and fails when the pod moves"
