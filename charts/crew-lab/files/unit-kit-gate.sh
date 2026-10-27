#!/usr/bin/env bash
# Argo CD PreSync gate: a change to the unit-kit pack restarts the lab server,
# so it waits for the human players to leave first.
#
#   SERVER_POD  <namespace>/<pod> of the lab server
#   WANT_REV    UNIT_KIT_REV the sync is about to roll out
#   NON_HUMAN   space-separated player-name patterns that do not count
#   WAIT_S      how long to wait for humans to leave before failing (default 600)
#   POLL_S      seconds between checks (default 30)
#
# Passes at once when the pod does not exist yet or already runs WANT_REV: a
# sync that does not restart the server is never held. A player is human unless
# NON_HUMAN names them or their latest connect line has an empty xuid (bots
# sign in offline). A player with no connect line counts as human, the safe way
# to be wrong. An unreadable player list fails the gate rather than passing it.
set -uo pipefail

: "${SERVER_POD:?}" "${WANT_REV:?}" "${NON_HUMAN:?}"
ns=${SERVER_POD%%/*}
pod=${SERVER_POD#*/}
wait_s=${WAIT_S:-600}
poll_s=${POLL_S:-30}

say() { echo "unit-kit-gate: $*"; }

if ! running=$(kubectl -n "$ns" get pod "$pod" \
  -o jsonpath='{.spec.initContainers[?(@.name=="install-unit-kit")].env[?(@.name=="UNIT_KIT_REV")].value}' 2>&1); then
  # Only a pod that is not there lets the sync through: any other error leaves
  # the running revision unknown.
  if [[ $running == *NotFound* ]]; then
    say "no $pod yet, nothing to restart"
    exit 0
  fi
  say "could not read $pod: $running"
  exit 1
fi
if [[ $running == "$WANT_REV" ]]; then
  say "kit revision $WANT_REV is already running"
  exit 0
fi
say "kit revision $running -> $WANT_REV restarts the lab server"

# Sets $humans to the names of people online; returns 1 when that cannot be
# read and 2 when the pod is confirmed not running (so nobody is on it).
check() {
  humans=
  if ! kubectl -n "$ns" exec "$pod" -- send-command list >/dev/null 2>&1; then
    # A failed exec alone proves nothing: a dropped stream or API timeout looks
    # the same while players are on. Only a pod read that succeeds and shows the
    # pod is not Running lets the sync through.
    local phase
    phase=$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null) || return 1
    [[ -n $phase && $phase != Running ]] && return 2
    return 1
  fi
  sleep "${SETTLE_S:-2}"
  local out block name pattern known connected line xuid
  out=$(kubectl -n "$ns" logs "$pod" --since=30s 2>/dev/null) || return 1
  block=$(grep -a -A1 'players online:' <<<"$out" | tail -n 2 | tr -d '\r')
  [[ -n $block ]] || return 1
  [[ $block == *'There are 0/'* ]] && return 0
  connected=
  for name in $(tail -n 1 <<<"$block" | tr ',' ' '); do
    known=false
    for pattern in $NON_HUMAN; do
      # shellcheck disable=SC2053 # Chart values deliberately use shell globs.
      [[ $name == $pattern ]] && known=true
    done
    [[ $known == true ]] && continue
    [[ -z $connected ]] && connected=$(kubectl -n "$ns" logs "$pod" 2>/dev/null | grep -a 'Player connected: ' || true)
    line=$(grep -aF "Player connected: $name, xuid:" <<<"$connected" | tail -n 1)
    xuid=${line#*xuid:}
    if [[ -z $line || $xuid == *[![:space:]]* ]]; then
      humans="$humans $name"
    fi
  done
  return 0
}

deadline=$((SECONDS + wait_s))
while :; do
  check
  rc=$?
  if [[ $rc == 2 ]]; then
    say "the server pod is not running, so nobody is on it"
    exit 0
  fi
  if [[ $rc == 0 && -z $humans ]]; then
    say "no human players online"
    exit 0
  fi
  if [[ $rc == 1 ]]; then
    say "could not read the player list"
  else
    say "waiting for:$humans"
  fi
  if ((SECONDS >= deadline)); then
    say "gave up after ${wait_s}s; sync again once the lab is empty"
    exit 1
  fi
  sleep "$poll_s"
done
