#!/usr/bin/env bash
# Exercises the deploy-announce PreSync hook's decision logic against staged
# states, and the digests that feed it.
#
# The hook decides whether players are told anything before a sync, and a
# wrong answer is either a silent restart or a warning about one that never
# comes. The shim below answers every read from staged values and records what
# would have been sent to the game instead of delivering it.
#
# The script and its environment are extracted from the rendered chart rather
# than copied here, so the test cannot drift away from what actually ships.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/minecraft-fwb"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

render() {
  helm template minecraft-fwb "$chart" \
    -f "$chart/values.yaml" -f "$chart/values-prd.yaml" \
    -f "$chart/values-console-bridge.yaml" -f "$chart/values-map-pack.yaml" "$@"
}

render > "$work/default.yaml"

# Writes the hook's script, and its env as a sourceable file so every case
# starts from exactly the variables the chart sets.
python3 - "$work/default.yaml" "$work" <<'PY'
import sys, shlex, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
job = next(d for d in docs if d["kind"] == "Job" and d["metadata"]["name"].endswith("-deploy-announce"))
c = job["spec"]["template"]["spec"]["containers"][0]
open(sys.argv[2] + "/hook.sh", "w").write(c["args"][0])
with open(sys.argv[2] + "/base.env", "w") as f:
    for e in c["env"]:
        f.write(f"{e['name']}={shlex.quote(e['value'])}\n")
PY
[ -s "$work/hook.sh" ] || fail "could not extract the hook script from the chart"

# The container's filesystem is read-only and bash backs a here-string or a
# here-document with a temp file, so either one fails there and nowhere else.
if grep -nE '<<' "$work/hook.sh" | grep -vE '< <\(' >/dev/null; then
  fail "the hook uses a here-string or here-document, which needs a writable temp directory"
fi

mkdir -p "$work/sa"
echo -n "test-ns" > "$work/sa/namespace"
sed -i "s|/var/run/secrets/kubernetes.io/serviceaccount/namespace|$work/sa/namespace|" "$work/hook.sh"

# The settle after `send-command list`. The shim answers at once, so every
# case would otherwise pay two seconds for nothing; the count is asserted so a
# new wait added to the hook fails this suite instead of quietly slowing it.
found="$(grep -c '^ *sleep 2$' "$work/hook.sh" || true)"
[ "$found" = "1" ] || fail "expected one 2s player-count settle to shorten, found $found"
sed -i 's/^\( *\)sleep 2$/\1sleep 0.1/' "$work/hook.sh"

set -a
# shellcheck source=/dev/null
. "$work/base.env"
set +a
live_server="$EXPECTED_SPEC_HASH" live_agent="$EXPECTED_AGENT_HASH" live_map="$EXPECTED_MAP_HASH"
[[ -n "$live_server" && -n "$live_agent" && -n "$live_map" ]] \
  || fail "the shipped values must render all three digests, got '$live_server' '$live_agent' '$live_map'"
agent_actor="${ACTOR_NAMES%%,*}"
[ -n "$agent_actor" ] || fail "the hook is not given the actors' gamertags"
set +a

mkdir -p "$work/bin"
cat > "$work/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1" == "exec" ]]; then
  # Recorded to a file because every exec the script makes is redirected away.
  [[ "$*" == *"tellraw"* ]] && echo "__TELLRAW__ $*" >> "$STATE_DIR/calls"
  exit 0
fi
if [[ "$1" == "get" ]]; then
  if [[ "$*" == "get pod"* && "$*" != *".ready"* ]]; then
    [[ "${FAKE_EXISTS:-yes}" == "no" ]] && exit 1
    exit 0
  fi
  [[ "$*" == *".ready"* ]] && { printf '%s' "${FAKE_READY:-true}"; exit 0; }
  [[ "$*" == *"data.hash"* ]] && { printf '%s' "$FAKE_LIVE_SERVER"; exit 0; }
  [[ "$*" == *"data.agentHash"* ]] && { printf '%s' "$FAKE_LIVE_AGENT"; exit 0; }
  [[ "$*" == *"data.mapHash"* ]] && { printf '%s' "$FAKE_LIVE_MAP"; exit 0; }
  exit 0
fi
[[ "$1" == "logs" ]] && { printf '%b\n' "${FAKE_LOGS:-There are 1/20 players online:\nSteve}"; exit 0; }
exit 0
SHIM
chmod +x "$work/bin/kubectl"

# Bounded: a hook that hangs is the failure that would hurt most here.
run() {
  rm -rf "$work/state"; mkdir -p "$work/state"
  local out rc=0 start=$SECONDS
  # Single quotes are deliberate: the variables expand in the inner shell.
  # shellcheck disable=SC2016
  out="$(timeout 60 bash -c '
      set -a; . "$1"; set +a; shift
      for kv in "$@"; do export "$kv"; done
      exec bash "$WORK/hook.sh"' _ "$work/base.env" \
      PATH="$work/bin:$PATH" STATE_DIR="$work/state" WORK="$work" LEAD_SECONDS=1 \
      FAKE_LIVE_SERVER="$live_server" FAKE_LIVE_AGENT="$live_agent" FAKE_LIVE_MAP="$live_map" \
      "$@" 2>&1)" || rc=$?
  # Through a file because run is called in a command substitution.
  echo $((SECONDS - start)) > "$work/elapsed"
  out="$out
$(cat "$work/state/calls" 2>/dev/null || true)"
  [ "$rc" -eq 0 ] || fail "the hook exited $rc and must never fail a sync: $out"
  printf '%s' "$out"
}

has()  { [[ "$1" == *"$2"* ]] || fail "$3: expected '$2' in: $1"; }
lacks() { [[ "$1" != *"$2"* ]] || fail "$3: '$2' appeared and must not have: $1"; }
tellraws() { grep -c '^__TELLRAW__' <<<"$1" || true; }

# --- map only ----------------------------------------------------------------
out="$(run FAKE_LIVE_MAP=old)"
has "$out" "Web map updating" "a map-only change announces the map"
has "$out" "game is not affected" "the message says the game is unaffected"
lacks "$out" "Server update incoming" "a map-only change"
lacks "$out" "seconds until" "a map-only change"
lacks "$out" "Updating now" "a map-only change"
[ "$(tellraws "$out")" = 1 ] || fail "a map-only change sends exactly one line: $out"
elapsed="$(cat "$work/elapsed")"
[ "$elapsed" -le 3 ] || fail "a map-only change held the sync for ${elapsed}s"
echo "  ok: a map-only change sends one line and no countdown"

out="$(run FAKE_LIVE_MAP=old MAP_MESSAGE='Map: back soon')"
has "$out" "Map: back soon" "the message is configurable"
lacks "$out" "Web map updating" "a configured message"
echo "  ok: the message is configurable"

# --- server change -----------------------------------------------------------
out="$(run FAKE_LIVE_SERVER=old FAKE_LIVE_MAP=old)"
has "$out" "Server update incoming" "a server change announces as before"
has "$out" "Updating now" "a server change finishes its countdown"
lacks "$out" "Web map updating" "a server change that also moves the map"
echo "  ok: a server change keeps its countdown and the map line is not sent separately"

out="$(run FAKE_LIVE_SERVER=old)"
has "$out" "Server update incoming" "a server-only change"
lacks "$out" "Web map updating" "a server-only change"
echo "  ok: a server-only change is unchanged"

out="$(run FAKE_LIVE_SERVER= FAKE_LIVE_AGENT= FAKE_LIVE_MAP=)"
has "$out" "Server update incoming" "a missing server digest still warns"
lacks "$out" "Web map updating" "a missing server digest"
echo "  ok: an empty ConfigMap still warns for the server and says nothing of the map"

# --- no change, first sync, disabled -----------------------------------------
out="$(run)"
[ "$(tellraws "$out")" = 0 ] || fail "no change must announce nothing: $out"
has "$out" "server spec unchanged" "no change"
echo "  ok: no change announces nothing"

out="$(run FAKE_LIVE_MAP=)"
[ "$(tellraws "$out")" = 0 ] || fail "a missing recorded map digest must not announce: $out"
echo "  ok: a missing recorded map digest announces nothing (the sync records it)"

out="$(run FAKE_LIVE_MAP=old MAP_ANNOUNCE=false)"
[ "$(tellraws "$out")" = 0 ] || fail "deployAnnounce.map.enabled=false must not announce: $out"
echo "  ok: map announcements can be turned off"

out="$(run FAKE_LIVE_MAP=old EXPECTED_MAP_HASH=)"
[ "$(tellraws "$out")" = 0 ] || fail "no map pod in this sync must not announce: $out"
echo "  ok: a sync with no map pod announces nothing"

# --- agent and map -----------------------------------------------------------
out="$(run FAKE_LIVE_AGENT=old FAKE_LIVE_MAP=old)"
has "$out" "Chat assistant updating" "agent and map together"
has "$out" "Web map updating" "agent and map together"
lacks "$out" "Server update incoming" "agent and map together"
[ "$(tellraws "$out")" = 2 ] || fail "agent and map send one short line each: $out"
echo "  ok: agent and map changing together send one short line each"

out="$(run FAKE_LIVE_AGENT=old)"
has "$out" "Chat assistant updating" "agent only"
lacks "$out" "Web map updating" "agent only"
echo "  ok: an agent-only change is unchanged"

# --- who is online -----------------------------------------------------------
out="$(run FAKE_LIVE_MAP=old FAKE_LOGS="There are 2/20 players online:\n$agent_actor, Steve")"
has "$out" "Web map updating" "an actor and a player"
echo "  ok: a player among the actors is announced to"

out="$(run FAKE_LIVE_MAP=old FAKE_LOGS="There are 1/20 players online:\n$agent_actor")"
[ "$(tellraws "$out")" = 0 ] || fail "only actors online must skip the announcement: $out"
has "$out" "only the server's own actors are online" "the skip says why"
echo "  ok: only the server's own actors online skips, and logs why"

out="$(run FAKE_LIVE_MAP=old FAKE_LOGS="There are 0/20 players online:")"
[ "$(tellraws "$out")" = 0 ] || fail "nobody online must skip the announcement: $out"
has "$out" "nobody online" "the skip says why"
echo "  ok: nobody online skips"

out="$(run FAKE_LIVE_MAP=old FAKE_LOGS="no list reply here")"
has "$out" "Web map updating" "an unreadable player count"
has "$out" "announcing anyway" "an unreadable player count"
echo "  ok: an unreadable player list announces anyway"

# A count that disagrees with the names read must not be trusted as actors-only.
out="$(run FAKE_LIVE_MAP=old FAKE_LOGS="There are 3/20 players online:\n$agent_actor")"
has "$out" "Web map updating" "a count the names do not account for"
echo "  ok: names that do not account for the count announce"

# --- the hook never blocks a sync --------------------------------------------
out="$(run FAKE_LIVE_MAP=old FAKE_EXISTS=no)"
[ "$(tellraws "$out")" = 0 ] || fail "an absent server pod has nobody to tell"
out="$(run FAKE_LIVE_MAP=old FAKE_READY=false)"
[ "$(tellraws "$out")" = 0 ] || fail "an unready server has nobody to tell"
echo "  ok: an absent or unready server is skipped with exit 0"

# --- the digests -------------------------------------------------------------
digests() {
  python3 -c '
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d["kind"] == "ConfigMap" and d["metadata"]["name"].endswith("-server-spec-hash"):
        print(d["data"]["hash"], d["data"]["agentHash"], d["data"]["mapHash"])
' "$1"
}
read -r base_server base_agent base_map < <(digests "$work/default.yaml")
[ "$base_map" = "$live_map" ] || fail "the ConfigMap and the hook disagree on the map digest"

render --set map.image.tag=0.0.0-test > "$work/map-image.yaml"
read -r s a m < <(digests "$work/map-image.yaml")
[ "$m" != "$base_map" ] || fail "a map image change must move the map digest"
[[ "$s" = "$base_server" && "$a" = "$base_agent" ]] || fail "a map image change moved the server or agent digest"

render --set map.resources.limits.memory=7Gi > "$work/map-res.yaml"
read -r s a m < <(digests "$work/map-res.yaml")
[ "$m" != "$base_map" ] || fail "map resources restart the pod and must move the digest"

render --set map.live.pollWait=7s > "$work/map-env.yaml"
read -r s a m < <(digests "$work/map-env.yaml")
[ "$m" != "$base_map" ] || fail "a map env value restarts the pod and must move the digest"

render --set map.host=elsewhere.example --set map.persistence.size=999Gi \
       --set map.alert.staleAfter=9h --set map.live.alert.lookback=9h > "$work/map-norestart.yaml"
read -r s a m < <(digests "$work/map-norestart.yaml")
[ "$m" = "$base_map" ] || fail "values that never reach the map's pod moved its digest and would announce a restart that is not coming"

render --set minecraft-bedrock.image.tag=0.0.0 > "$work/server-change.yaml"
read -r s a m < <(digests "$work/server-change.yaml")
[[ "$s" != "$base_server" && "$m" = "$base_map" ]] || fail "a server image change must move only the server digest"

render --set deployAnnounce.map.enabled=false > "$work/map-off.yaml"
read -r s a m < <(digests "$work/map-off.yaml")
[ "$m" = "$base_map" ] || fail "turning the notice off must not stop the digest being recorded"
render --set map.enabled=false > "$work/no-map.yaml"
read -r s a m < <(digests "$work/no-map.yaml")
[ -z "${m:-}" ] || fail "with no map pod the digest must be empty, got '$m'"
echo "  ok: the map digest moves with the map's pod and nothing else"
