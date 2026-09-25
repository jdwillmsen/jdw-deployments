#!/usr/bin/env bash
# Exercises `tools/mc presence` against fake kubectl and curl, so it runs in CI
# with no cluster and no agent.
#
# The fakes answer from fixture files named after the request, and record
# every request and every argv, so what was sent -- and what was not, like the
# token on a command line -- is asserted rather than assumed.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
mc="$here/tools/mc"
chart="$here/charts/minecraft-fwb"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

TOKEN="s3cret-operator-token"
mkdir -p "$work/bin" "$work/fx" "$work/fx-off"

cat > "$work/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBECTL_LOG"
printf 'kubectl %s\n' "${MC_PRESENCE_TOKEN-}" >> "$ENV_LOG"
case "$1" in
  get)
    [ -n "${FAKE_NO_SECRET:-}" ] && { echo 'Error from server (NotFound): secrets not found' >&2; exit 1; }
    printf '%s' "$(printf '%s' "$FAKE_TOKEN" | base64)" ;;
  port-forward)
    [ -n "${FAKE_NO_SERVICE:-}" ] && { echo 'Error from server (NotFound): services not found'; exit 1; }
    echo "Forwarding from 127.0.0.1:40123 -> 9090"
    exec sleep 30 ;;
esac
SHIM

# Answers from $FIXTURES/<METHOD><path with / as _>.json, status from a
# sibling .code file (default 200). Records the Authorization header it was
# handed on stdin, so the test can prove the token arrived that way.
cat > "$work/bin/curl" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
printf 'curl %s\n' "${MC_PRESENCE_TOKEN-}" >> "$ENV_LOG"
method=GET body="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data-binary) body="$2"; shift 2 ;;
    -H|-w|--max-time) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
header="$(cat)"
path="${url#http://*/}"
printf '%s /%s %s\n' "$method" "$path" "$body" >> "$CAPTURE"
printf '%s\n' "$header" >> "$HEADERS"
slug="$method$(printf '/%s' "$path" | tr '/' '_')"
code=200
[ -f "$FIXTURES/$slug.code" ] && code="$(cat "$FIXTURES/$slug.code")"
[ -f "$FIXTURES/$slug.json" ] && cat "$FIXTURES/$slug.json"
printf '\n%s' "$code"
SHIM

# jq only records what it inherited, then runs for real.
cat > "$work/bin/jq" <<SHIM
#!/usr/bin/env bash
printf 'jq %s\\n' "\${MC_PRESENCE_TOKEN-}" >> "\$ENV_LOG"
exec $(command -v jq) "\$@"
SHIM
chmod +x "$work/bin/kubectl" "$work/bin/curl" "$work/bin/jq"

# afk-bot-1 parked from the CLI with an expiry; afk-bot-2 and the agent at
# their defaults. The agent reports no status, so `connected` must say null
# rather than false.
cat > "$work/fx/GET_v1_actors.json" <<'JSON'
[{"id":"agent","gamertag":"JDWServerAgent","kind":"agent","groups":[],"actor_id":"agent","effective":"present","default":"present"},
 {"id":"afk-bot-1","gamertag":"LightBlaz3","kind":"afk-bot","groups":["bots"],"actor_id":"afk-bot-1","effective":"parked","default":"present",
  "override":{"state":"parked","until":"2026-09-23T12:00:00Z","reason":"farm rebuild","set_by":"api:tools-mc","set_at":"2026-09-23T10:00:00Z","version":3},
  "status":{"connected":false,"observed_state":"parked","last_seen":"2026-09-23T10:00:05Z","process_version":"1.2.0"}},
 {"id":"afk-bot-2","gamertag":"Dotablaze7321","kind":"afk-bot","groups":["bots"],"actor_id":"afk-bot-2","effective":"present","default":"present",
  "status":{"connected":true,"observed_state":"present","last_seen":"2026-09-23T10:00:07Z","process_version":"1.2.0"}}]
JSON

# What Go's ServeMux answers for /v1 when the agent has not mounted it: with
# presence off, or while a starting pod is still opening its store.
printf '404 page not found' > "$work/fx-off/GET_v1_actors.json"
echo 404 > "$work/fx-off/GET_v1_actors.code"

run() {
  : > "$work/capture"; : > "$work/argv"; : > "$work/headers"; : > "$work/kubectl"; : > "$work/env"
  env PATH="$work/bin:$PATH" MC_NAMESPACE=test-ns FIXTURES="$work/fx" FAKE_TOKEN="$TOKEN" \
      CAPTURE="$work/capture" ARGV_LOG="$work/argv" HEADERS="$work/headers" KUBECTL_LOG="$work/kubectl" \
      ENV_LOG="$work/env" \
      "$@"
}

# --- ls ----------------------------------------------------------------------
set +e
out="$(run bash "$mc" presence ls)"; rc=$?
set -e
[ "$rc" = 0 ] || fail "ls exited $rc: $out"
grep -qx 'count: 3' <<<"$out" || fail "ls must state the total: $out"
grep -qx 'actors\[3\]{id,effective,source,until,connected}:' <<<"$out" || fail "ls must print a TOON table header: $out"
grep -qx '  agent,present,default,null,null' <<<"$out" || fail "an actor at its default reads as source default, no status as null: $out"
grep -qx '  afk-bot-1,parked,"api:tools-mc","2026-09-23T12:00:00Z",false' <<<"$out" || fail "values with a colon are quoted and false stays false: $out"
grep -qx '  afk-bot-2,present,default,null,true' <<<"$out" || fail "a connected bot reads true: $out"
grep -qx 'groups\[2\]: bots,all' <<<"$out" || fail "ls must list the groups a target can name: $out"
grep -q '^help\[2\]:' <<<"$out" || fail "ls must offer next steps: $out"
echo "  ok: ls prints actors as TOON with counts, groups and next steps"

out2="$(run bash "$mc" presence)"
[ "$out2" = "$out" ] || fail "bare presence must be ls: $out2"
echo "  ok: bare presence lists"

grep -q 'port-forward -n test-ns svc/jdwillmsen-minecraft-fwb-prd-server-agent-metrics :9090' "$work/kubectl" \
  || fail "ls must reach the API through the agent's metrics Service: $(cat "$work/kubectl")"
grep -q 'http://127.0.0.1:40123/v1/actors' "$work/argv" || fail "ls must call the forwarded port: $(cat "$work/argv")"
echo "  ok: ls reaches the agent's metrics Service through a port-forward"

# --- the token -----------------------------------------------------------------
grep -qx "Authorization: Bearer $TOKEN" "$work/headers" || fail "the token must reach curl as the Authorization header"
grep -qF "$TOKEN" "$work/argv" && fail "the token appeared in curl's argv, which ps shows to every user"
grep -qF "$TOKEN" "$work/kubectl" && fail "the token appeared in a kubectl argv"
grep -qF "$TOKEN" <<<"$out" && fail "the token appeared in the output"
echo "  ok: the token reaches curl on stdin and is never printed"

# The CLI names the secret key itself; the chart is what actually writes it.
# Read the key the CLI asked for back out of a real render, so a rename on
# either side fails here rather than as an empty token in production.
secret_get="$(grep '^get secret' "$work/kubectl")"
grep -q 'get secret -n test-ns jdwillmsen-minecraft-fwb-prd-presence ' <<<"$secret_get" \
  || fail "ls must read the chart's presence secret: $secret_get"
key="$(grep -oE '\{\.data\.[a-z0-9_]+\}' <<<"$secret_get" | sed 's/{\.data\.//;s/}//')"
rendered="$(helm template jdwillmsen-minecraft-fwb-prd "$chart" -n jdwillmsen-prd \
  -f "$chart/values.yaml" -f "$chart/values-prd.yaml" -f "$chart/values-console-bridge.yaml" \
  --set global.presence.enabled=true)"
grep -qx "    - secretKey: $key" <<<"$rendered" \
  || fail "the chart renders no secret key $key for the CLI to read"
grep -qx '  name: jdwillmsen-minecraft-fwb-prd-presence' <<<"$rendered" \
  || fail "the chart renders no jdwillmsen-minecraft-fwb-prd-presence secret"
echo "  ok: the secret and key the CLI reads are the ones the chart renders"

# Tracing is how a failure gets debugged, and xtrace prints every expanded
# assignment -- so a trace must not carry the token either.
set +e
traced="$(run bash -x "$mc" presence ls 2>&1)"
traced_env="$(run env MC_PRESENCE_URL=http://agent.test MC_PRESENCE_TOKEN=env-token-value bash -x "$mc" presence ls 2>&1)"
set -e
grep -q '^count: 3' <<<"$traced" || fail "ls must still work under xtrace: $traced"
grep -qF "$TOKEN" <<<"$traced" && fail "the cluster token appeared in an xtrace"
grep -qF "$(printf '%s' "$TOKEN" | base64)" <<<"$traced" && fail "the encoded token appeared in an xtrace"
grep -qF "env-token-value" <<<"$traced_env" && fail "MC_PRESENCE_TOKEN appeared in an xtrace"
echo "  ok: the token stays out of an xtrace"

out="$(run env MC_PRESENCE_URL=http://agent.test MC_PRESENCE_TOKEN=from-env bash "$mc" presence ls)"
grep -qx "Authorization: Bearer from-env" "$work/headers" || fail "MC_PRESENCE_TOKEN must override the cluster secret"
[ ! -s "$work/kubectl" ] || fail "with URL and token given, nothing may touch the cluster: $(cat "$work/kubectl")"
echo "  ok: MC_PRESENCE_URL and MC_PRESENCE_TOKEN bypass the cluster"

# A child's environment is readable from /proc by the same user for as long as
# it runs, and the port-forward runs for the whole command.
for args in "ls" "park bots --for 2h --reason env-check" "unpark afk-bot-1"; do
  # shellcheck disable=SC2086  # word splitting is the point: each case is an argv
  out="$(run env MC_PRESENCE_TOKEN=env-token-value bash "$mc" presence $args)" || fail "'presence $args' must succeed: $out"
  for child in kubectl curl jq; do
    grep -q "^$child " "$work/env" \
      || fail "'presence $args' did not run $child, so its environment went unchecked: $(cat "$work/env")"
  done
  grep -qF "env-token-value" "$work/env" && fail "'presence $args' passed MC_PRESENCE_TOKEN on to a child: $(cat "$work/env")"
done
echo "  ok: MC_PRESENCE_TOKEN is not inherited by kubectl, curl or jq"

# --- errors ----------------------------------------------------------------------
set +e
out="$(run env FAKE_NO_SERVICE=1 bash "$mc" presence ls)"; rc=$?
set -e
[ "$rc" = 1 ] || fail "an unreachable API must exit 1, got $rc"
grep -q '^error: could not reach the presence API' <<<"$out" || fail "an unreachable API must say so: $out"
grep -q '^hint: the server agent may be off or restarting' <<<"$out" || fail "an unreachable API must suggest why: $out"
grep -q 'Error from server' <<<"$out" && fail "kubectl's own error text leaked: $out"
echo "  ok: a missing metrics Service is reported, not leaked"

set +e
out="$(run env FIXTURES="$work/fx-off" bash "$mc" presence ls)"; rc=$?
set -e
[ "$rc" = 1 ] || fail "an unmounted API must exit 1, got $rc"
grep -q '^error: the agent is not serving the presence API' <<<"$out" || fail "an unmounted API must say so: $out"
grep -q '^hint: presence may be off' <<<"$out" || fail "an unmounted API must suggest why: $out"
grep -q 'page not found' <<<"$out" && fail "the raw body leaked: $out"
echo "  ok: presence off (plain-text 404) is reported as such"

set +e
out="$(run env FAKE_NO_SECRET=1 bash "$mc" presence ls)"; rc=$?
set -e
[ "$rc" = 1 ] || fail "a missing secret must exit 1, got $rc"
grep -q '^error: no operator token in secret jdwillmsen-minecraft-fwb-prd-presence' <<<"$out" || fail "a missing secret must say so: $out"
grep -q '^hint: presence may be off' <<<"$out" || fail "a missing secret must suggest why: $out"
grep -q 'Error from server' <<<"$out" && fail "kubectl's own error text leaked: $out"
echo "  ok: a missing presence secret is reported"

echo 401 > "$work/fx/GET_v1_actors.code"
set +e
out="$(run bash "$mc" presence ls)"; rc=$?
set -e
[ "$rc" = 1 ] || fail "a 401 must exit 1, got $rc"
grep -q '^error: the presence API rejected the operator token' <<<"$out" || fail "a 401 must be translated: $out"
echo "  ok: a rejected token is translated"

cp "$work/fx/GET_v1_actors.json" "$work/actors.json"
echo 503 > "$work/fx/GET_v1_actors.code"
echo '{"code":"unavailable","message":"the presence store is unavailable; retry"}' > "$work/fx/GET_v1_actors.json"
set +e
out="$(run bash "$mc" presence ls)"; rc=$?
set -e
[ "$rc" = 1 ] || fail "a 503 must exit 1, got $rc"
grep -q '^error: the presence store is unavailable' <<<"$out" || fail "a 503 must be translated: $out"
echo "  ok: an unavailable store is translated"

echo 200 > "$work/fx/GET_v1_actors.code"
echo '{"not":"a list"}' > "$work/fx/GET_v1_actors.json"
set +e
out="$(run bash "$mc" presence ls)"; rc=$?
set -e
[ "$rc" = 1 ] || fail "a malformed answer must exit 1, got $rc"
grep -q '^error: the presence API answered something other than a list of actors' <<<"$out" || fail "a malformed answer must say so: $out"
rm "$work/fx/GET_v1_actors.code"; mv "$work/actors.json" "$work/fx/GET_v1_actors.json"
echo "  ok: a malformed answer is refused"

set +e
out="$(run bash "$mc" presence ls --bogus)"; rc=$?
set -e
[ "$rc" = 2 ] || fail "an unknown flag must exit 2, got $rc"
grep -q '^hint: valid flags for presence ls: --help' <<<"$out" || fail "an unknown flag must list the valid ones: $out"
[ ! -s "$work/kubectl" ] || fail "a usage error must be caught before touching the cluster"
echo "  ok: unknown flags exit 2 before any call"

set +e
out="$(run bash "$mc" presence frobnicate)"; rc=$?
set -e
[ "$rc" = 2 ] || fail "an unknown subcommand must exit 2, got $rc"
echo "  ok: unknown subcommands exit 2"

out="$(run bash "$mc" presence --help)"
grep -q 'presence park <target> --reason' <<<"$out" || fail "presence --help must document park: $out"
out="$(run bash "$mc" presence ls --help)"
grep -q 'presence unpark <target>' <<<"$out" || fail "presence ls --help must print the presence help: $out"
grep -q 'presence \[ls|park|unpark\]' <<<"$(run bash "$mc" --help)" || fail "mc --help must list presence"
echo "  ok: presence --help documents every subcommand"

# --- park --------------------------------------------------------------------
cat > "$work/fx/PUT_v1_groups_bots_presence.json" <<'JSON'
[{"actor_id":"afk-bot-1","effective":"parked","default":"present","override":{"state":"parked","until":"2026-09-23T12:00:00Z","reason":"farm rebuild","set_by":"api:tools-mc","set_at":"2026-09-23T10:00:00Z","version":4}},
 {"actor_id":"afk-bot-2","effective":"parked","default":"present","override":{"state":"parked","until":"2026-09-23T12:00:00Z","reason":"farm rebuild","set_by":"api:tools-mc","set_at":"2026-09-23T10:00:00Z","version":1}}]
JSON
out="$(run bash "$mc" presence park bots --for 2h --reason "farm rebuild")"
grep -qx 'PUT /v1/groups/bots/presence {"state":"parked","reason":"farm rebuild","version":0,"duration":"2h"}' "$work/capture" \
  || fail "a group park must PUT the group route with the duration: $(cat "$work/capture")"
grep -qx 'parked\[2\]{id,effective,until}:' <<<"$out" || fail "park must list what it parked: $out"
grep -qx '  afk-bot-2,parked,"2026-09-23T12:00:00Z"' <<<"$out" || fail "park must show each expiry: $out"
grep -q 'presence unpark bots' <<<"$out" || fail "park must say how to undo it: $out"
echo "  ok: parking a group sends one group write with the duration"

cat > "$work/fx/PUT_v1_actors_afk-bot-1_presence.json" <<'JSON'
{"actor_id":"afk-bot-1","effective":"parked","default":"present","override":{"state":"parked","reason":"moving it","set_by":"api:tools-mc","set_at":"2026-09-23T10:00:00Z","version":4}}
JSON
out="$(run bash "$mc" presence park afk-bot-1 --reason "moving it")"
grep -qx 'PUT /v1/actors/afk-bot-1/presence {"state":"parked","reason":"moving it","version":3}' "$work/capture" \
  || fail "an actor park must carry the version it read and no duration: $(cat "$work/capture")"
grep -qx '  afk-bot-1,parked,null' <<<"$out" || fail "a park without --for has no expiry: $out"
echo "  ok: parking one actor writes against the version it read"

echo 409 > "$work/fx/PUT_v1_actors_afk-bot-1_presence.code"
cat > "$work/fx/PUT_v1_actors_afk-bot-1_presence.json" <<'JSON'
{"code":"conflict","message":"version mismatch","current":{"actor_id":"afk-bot-1","effective":"present","default":"present","override":{"state":"present","reason":"back now","set_by":"chat:Steve","set_at":"2026-09-23T10:01:00Z","version":4}}}
JSON
set +e
out="$(run bash "$mc" presence park afk-bot-1 --reason "moving it")"; rc=$?
set -e
rm "$work/fx/PUT_v1_actors_afk-bot-1_presence.code"
[ "$rc" = 1 ] || fail "a conflict must exit 1, got $rc"
grep -qx 'current: afk-bot-1,present,"chat:Steve"' <<<"$out" || fail "a conflict must show who changed it: $out"
[ "$(grep -c '^PUT' "$work/capture")" = 1 ] || fail "a conflict must not be retried over someone else's change"
echo "  ok: a conflicting edit is shown, not overwritten"

for args in "park bots --for 2h" "park bots --reason x --for soon" "park bots --reason x --for 0s" "park --reason x" "park Bots --reason x" \
            "park bots --reason x --force" "park bots extra --reason x"; do
  set +e
  # shellcheck disable=SC2086  # word splitting is the point: each case is an argv
  out="$(run bash "$mc" presence $args)"; rc=$?
  set -e
  [ "$rc" = 2 ] || fail "'presence $args' must be a usage error (exit 2), got $rc: $out"
  grep -q '^error:' <<<"$out" || fail "'presence $args' must say what is wrong: $out"
  grep -q '^hint:' <<<"$out" || fail "'presence $args' must say what to run instead: $out"
done
[ ! -s "$work/kubectl" ] || fail "usage errors must be caught before touching the cluster"
echo "  ok: a missing reason, bad duration, bad target or unknown flag exits 2 before any call"

set +e
out="$(run bash "$mc" presence park bost --reason x)"; rc=$?
set -e
[ "$rc" = 1 ] || fail "an unknown target must exit 1, got $rc"
grep -q '^hint: targets are agent, afk-bot-1, afk-bot-2, bots, all' <<<"$out" || fail "an unknown target must list the real ones: $out"
grep -q '^PUT' "$work/capture" && fail "an unknown target must write nothing"
echo "  ok: an unknown target is refused before anything is written"

# A parked agent reads no chat, so a park of it with no expiry has no way back
# but this tool. The warning says so; any other park stays quiet.
cat > "$work/fx/PUT_v1_actors_agent_presence.json" <<'JSON'
{"actor_id":"agent","effective":"parked","default":"present","override":{"state":"parked","reason":"quiet","set_by":"api:tools-mc","set_at":"2026-09-23T10:00:00Z","version":1}}
JSON
cat > "$work/fx/PUT_v1_groups_all_presence.json" <<'JSON'
[{"actor_id":"agent","effective":"parked","default":"present","override":{"state":"parked","reason":"quiet","set_by":"api:tools-mc","set_at":"2026-09-23T10:00:00Z","version":1}}]
JSON
warning='warning: agent parked with no expiry; chat cannot unpark it; run: mc presence unpark agent'
for args in "park agent --reason quiet" "park all --reason quiet"; do
  set +e
  # shellcheck disable=SC2086  # word splitting is the point: each case is an argv
  out="$(run bash "$mc" presence $args)"; rc=$?
  set -e
  [ "$rc" = 0 ] || fail "'presence $args' is a warning, not an error (rc=$rc): $out"
  grep -qxF "$warning" <<<"$out" || fail "'presence $args' must warn that only this tool can bring the agent back: $out"
done
for args in "park agent --for 1h --reason quiet" "park bots --reason quiet" "park afk-bot-1 --reason quiet"; do
  # shellcheck disable=SC2086
  out="$(run bash "$mc" presence $args)" || fail "'presence $args' must succeed: $out"
  grep -q '^warning:' <<<"$out" && fail "'presence $args' must not warn: $out"
done
echo "  ok: only a park of the agent with no expiry warns, and still exits 0"

# --- unpark ------------------------------------------------------------------
cat > "$work/fx/DELETE_v1_actors_afk-bot-1_presence.json" <<'JSON'
{"actor_id":"afk-bot-1","effective":"present","default":"present"}
JSON
out="$(run bash "$mc" presence unpark bots)"
[ "$(grep -c '^DELETE' "$work/capture")" = 1 ] || fail "only actors with an override are unparked: $(cat "$work/capture")"
grep -qx 'DELETE /v1/actors/afk-bot-1/presence ' "$work/capture" || fail "unpark must DELETE the override: $(cat "$work/capture")"
grep -qx 'unparked\[1\]{id,effective}:' <<<"$out" || fail "unpark must print a TOON table: $out"
grep -qx '  afk-bot-1,present' <<<"$out" || fail "unpark must show the restored state: $out"
grep -qx 'unchanged\[1\]: afk-bot-2' <<<"$out" || fail "unpark must name what was already at its default: $out"
echo "  ok: unparking a group removes each member's override"

set +e
out="$(run bash "$mc" presence unpark afk-bot-2)"; rc=$?
set -e
[ "$rc" = 0 ] || fail "unparking an actor at its default is a no-op, not an error (rc=$rc)"
grep -q 'no-op' <<<"$out" || fail "a no-op must say so: $out"
grep -q '^DELETE' "$work/capture" && fail "a no-op must write nothing"
echo "  ok: unparking what is not parked is an explicit no-op"

# Both bots parked, the second DELETE fails: what already happened is stated.
jq '.[2].override = .[1].override' "$work/fx/GET_v1_actors.json" > "$work/fx/both.json"
mv "$work/fx/both.json" "$work/fx/GET_v1_actors.json"
echo 503 > "$work/fx/DELETE_v1_actors_afk-bot-2_presence.code"
echo '{"code":"unavailable","message":"store unavailable"}' > "$work/fx/DELETE_v1_actors_afk-bot-2_presence.json"
set +e
out="$(run bash "$mc" presence unpark bots)"; rc=$?
set -e
[ "$rc" = 1 ] || fail "a failed member must fail the command, got $rc"
grep -qx 'unparked_before_failure: afk-bot-1' <<<"$out" || fail "a partial unpark must name what it already did: $out"
grep -q '^error: the presence store is unavailable' <<<"$out" || fail "the failure must be translated: $out"
echo "  ok: a partial group unpark reports what it did before failing"

# --- the token on writes -------------------------------------------------------
# park and unpark carry the token too, and a write is where a leak would cost
# most: the same argv and xtrace checks as ls, per write command.
for args in "park bots --for 2h --reason token-check" "unpark afk-bot-1"; do
  # shellcheck disable=SC2086  # word splitting is the point: each case is an argv
  run bash "$mc" presence $args >/dev/null || fail "'presence $args' must succeed"
  grep -qx "Authorization: Bearer $TOKEN" "$work/headers" || fail "'presence $args' must send the token as a stdin header"
  grep -qF "$TOKEN" "$work/argv" && fail "'presence $args' put the token in curl's argv"
  grep -qF "$TOKEN" "$work/kubectl" && fail "'presence $args' put the token in a kubectl argv"
  set +e
  # shellcheck disable=SC2086
  traced="$(run bash -x "$mc" presence $args 2>&1)"; rc=$?
  # shellcheck disable=SC2086
  traced_env="$(run env MC_PRESENCE_URL=http://agent.test MC_PRESENCE_TOKEN=env-token-value bash -x "$mc" presence $args 2>&1)"
  set -e
  [ "$rc" = 0 ] || fail "'presence $args' must still work under xtrace: $traced"
  grep -qF "$TOKEN" <<<"$traced" && fail "the cluster token appeared in an xtrace of 'presence $args'"
  grep -qF "$(printf '%s' "$TOKEN" | base64)" <<<"$traced" && fail "the encoded token appeared in an xtrace of 'presence $args'"
  grep -qF "env-token-value" <<<"$traced_env" && fail "MC_PRESENCE_TOKEN appeared in an xtrace of 'presence $args'"
done
echo "  ok: park and unpark keep the token off argv and out of an xtrace"

# --- the runbook's own commands --------------------------------------------------
# README's "Parking actors" is where an operator copies these from, so each one
# must still parse. Anything but a usage error (exit 2) is fine here: the fakes
# decide the outcome, the grammar is what is under test.
mapfile -t documented < <(grep -oE '^tools/mc presence[^#]*' "$here/README.md" | sed 's/ *$//')
[ "${#documented[@]}" -ge 3 ] || fail "README shows fewer than three tools/mc presence commands"
for line in "${documented[@]}"; do
  mapfile -t argv < <(python3 -c 'import shlex, sys; print("\n".join(shlex.split(sys.argv[1])[1:]))' "$line")
  set +e
  out="$(run bash "$mc" "${argv[@]}")"; rc=$?
  set -e
  [ "$rc" != 2 ] || fail "README documents a command the CLI rejects: $line -> $out"
done
echo "  ok: every tools/mc presence command in the README parses"

echo "PASS"
