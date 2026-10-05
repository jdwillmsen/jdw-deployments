#!/usr/bin/env bash
# Exercises `tools/mc cull` against a fake kubectl, so it runs in CI with no
# cluster and no server.
#
# The fake keeps the one piece of server state the command must never leak:
# which ticking areas exist, in which dimension. It adds and removes them as
# the real console would -- a remove in the wrong dimension is a silent no-op
# -- so "nothing is left force-loaded" is asserted against state rather than
# against the commands the tool chose to send.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
mc="$here/tools/mc"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$work/bin" "$work/fx"
cat > "$work/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
state="$STATE/areas"
console="$STATE/console"
touch "$state" "$console"
stamp='[2026-10-05 03:31:18:762'
in_use() { echo "$(( $(wc -l < "$state") + ${FAKE_FOREIGN_AREAS:-0} ))"; }
# What the real console prints for a remove: the area's own name, in the same
# `- name: from to` form the list uses. A check that reads names out of a time
# window takes this echo for an area that is still there.
remove() {
  local dim="$1" name="$2"
  if [ "$name" != "${FAKE_STUCK:-}" ] && grep -q -x "$dim $name" "$state"; then
    grep -v -x "$dim $name" "$state" > "$state.new" || true
    mv "$state.new" "$state"
    printf '%s INFO] Removed ticking area(s)\n- %s: 0 0 0 to 15 0 15\n%s/10 ticking areas in use.\n' "$stamp" "$name" "$(in_use)" >> "$console"
  else
    printf "%s ERROR] No ticking areas named %s exist in the current dimension.\nFailed to execute 'tickingarea' as [Null]\n" "$stamp" "$name" >> "$console"
  fi
}
case "$1" in
  get)
    case "$*" in
      *"get job"*succeeded*) [ -n "${FAKE_JOB_FAILS:-}" ] || printf 1 ;;
      *"get job"*failed*)    [ -n "${FAKE_JOB_FAILS:-}" ] && printf 1 ;;
      *) printf 'server-0' ;;
    esac ;;
  create)
    printf '%s' '{"metadata":{"name":"listing"},"spec":{"template":{"spec":{"containers":[{"name":"metrics-publish","args":["keep"]},{"name":"census","args":["-world-dir","/snapshot","-metrics-file","/tmp/metrics.txt"]}]}}}}' ;;
  apply)
    n="$(cat "$STATE/listings" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$STATE/listings"
    while [ $# -gt 0 ]; do [ "$1" = "-f" ] && cp "$2" "$STATE/job-$n.json"; shift; done ;;
  delete) printf 'delete %s\n' "$*" >> "$CAPTURE" ;;
  logs)
    case "$*" in
      *job/*)
        [ -n "${FAKE_JOB_FAILS:-}" ] && { echo "census: parse flags: flag provided but not defined: -list"; exit 0; }
        cat "$FIXTURES/listing-$(cat "$STATE/listings").ndjson" ;;
      *)
        printf 'noise \x00 binary\n'
        [ -n "${FAKE_KILLED:-}" ] && printf '%s INFO] Killed %s\n' "$stamp" "$FAKE_KILLED"
        [ -n "${FAKE_SILENT:-}" ] || cat "$console" ;;
    esac ;;
  exec)
    shift; while [[ "$1" != "--" ]]; do shift; done; shift 2
    printf '%s\n' "$*" >> "$CAPTURE"
    [ -n "${FAKE_FAIL_ON:-}" ] && [[ "$*" == *"$FAKE_FAIL_ON"* ]] && exit 1
    if [[ "$*" =~ ^execute\ in\ ([a-z_]+)\ run\ tickingarea\ add\ .*\ ([a-z0-9]+)$ ]]; then
      echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}" >> "$state"
      printf '%s INFO] Added ticking area from 0, 0, 0 to 15, 0, 15.\n%s/10 ticking areas in use.\n' "$stamp" "$(in_use)" >> "$console"
    elif [[ "$*" =~ ^execute\ in\ ([a-z_]+)\ run\ tickingarea\ remove\ ([a-z0-9]+)$ ]]; then
      remove "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ "$*" =~ ^tickingarea\ remove\ ([a-z0-9]+)$ ]]; then
      # The console sits in the overworld.
      remove overworld "${BASH_REMATCH[1]}"
    elif [[ "$*" == "tickingarea list all-dimensions" ]]; then
      if [ "$(in_use)" -eq 0 ]; then
        printf '%s ERROR] No ticking areas exist in any dimension.\n' "$stamp" >> "$console"
      else
        printf '%s INFO] §aList of all ticking areas in all dimensions\nOverworld: \n' "$stamp" >> "$console"
        while read -r _ name; do echo "- $name: 0 0 0 to 15 0 15"; done < "$state" >> "$console"
        printf '%s/10 ticking areas in use.\n%s INFO] Gametime is 563808326\n' "$(in_use)" "$stamp" >> "$console"
      fi
    else
      printf "%s ERROR] No targets matched selector\nFailed to execute 'kill' as [Null]\n" "$stamp" >> "$console"
    fi ;;
esac
exit 0
SHIM
chmod +x "$work/bin/kubectl"

# Two far-apart overworld zombies, an enderman in the End, and a name-tagged
# zombie with an unnamed one standing beside it.
cat > "$work/fx/listing-1.ndjson" <<'JSON'
{"world_taken_at":"2026-10-05T03:16:47Z","source":"snapshot","types":["enderman","zombie"],"entities":5,"orphaned":1913}
{"identifier":"enderman","dimension":"end","x":-3000.5,"y":60,"z":-600.5,"persistent":false}
{"identifier":"zombie","dimension":"overworld","x":10.5,"y":64,"z":20.5,"persistent":true}
{"identifier":"zombie","dimension":"overworld","x":700.5,"y":70,"z":700.5,"persistent":false}
{"identifier":"zombie","dimension":"overworld","x":2000.5,"y":64,"z":2000.5,"persistent":true,"name":"Bob"}
{"identifier":"zombie","dimension":"overworld","x":2010.5,"y":64,"z":2005.5,"persistent":false}
JSON
# Afterwards: the three targets are gone, Bob and his neighbour are where
# they were, and one zombie has spawned somewhere new.
cat > "$work/fx/listing-2.ndjson" <<'JSON'
{"world_taken_at":"2026-10-05T03:46:04Z","source":"snapshot","types":["enderman","zombie"],"entities":3,"orphaned":1913}
{"identifier":"zombie","dimension":"overworld","x":55.5,"y":64,"z":60.5,"persistent":false}
{"identifier":"zombie","dimension":"overworld","x":2000.5,"y":64,"z":2000.5,"persistent":true,"name":"Bob"}
{"identifier":"zombie","dimension":"overworld","x":2010.5,"y":64,"z":2005.5,"persistent":false}
JSON

rc=0
run() {
  rm -rf "$work/state"; mkdir -p "$work/state"; : > "$work/sent"
  rc=0
  out="$(env PATH="$work/bin:$PATH" CAPTURE="$work/sent" STATE="$work/state" FIXTURES="$work/fx" \
    MC_NAMESPACE=test-ns MC_CULL_LOAD_WAIT=0 MC_CULL_KILL_GAP=0 MC_CULL_POLL=0 MC_CULL_REPLY_POLL=0 "$@" 2>&1)" || rc=$?
}
sent() { grep -c -- "$1" "$work/sent" || true; }
areas_left() { wc -l < "$work/state/areas" | tr -d ' '; }

# --- refusing to start ----------------------------------------------------
run bash "$mc" cull --types zombie
[ "$rc" -eq 2 ] || fail "cull with neither --dry-run nor --confirm must be a usage error, got $rc: $out"
[ ! -s "$work/sent" ] || fail "a refused cull reached the server: $(cat "$work/sent")"
[ ! -e "$work/state/listings" ] || fail "a refused cull took a snapshot"
echo "  ok: a cull with no mode is refused before anything runs"

run bash "$mc" cull --dry-run
[ "$rc" -eq 2 ] || fail "cull without --types must be a usage error"
# shellcheck disable=SC2016  # the literal substitution is the input under test
run bash "$mc" cull --types 'zombie,$(id)' --confirm
[ "$rc" -eq 2 ] || fail "a type that is not a plain identifier must be refused, got $rc"
[ ! -s "$work/sent" ] || fail "a hostile type reached the server: $(cat "$work/sent")"
run bash "$mc" cull --types zombie --dry-run --confirm
[ "$rc" -eq 2 ] || fail "--dry-run with --confirm must be refused"
echo "  ok: missing, hostile and contradictory arguments are usage errors"

# --- the dry run ----------------------------------------------------------
run bash "$mc" cull --types enderman,zombie --dry-run
[ "$rc" -eq 0 ] || fail "dry run failed: $out"
grep -q '^targets: 3$' <<<"$out" || fail "dry run must count the three targets it would kill: $out"
grep -q '^regions: 3$' <<<"$out" || fail "dry run must count the regions it would load: $out"
grep -q 'the_end: 1 regions, 1 targets' <<<"$out" || fail "dry run must break the plan down by dimension: $out"
grep -q '^named_spared: 1$' <<<"$out" || fail "dry run must say a name-tagged mob is spared: $out"
grep -q '"Bob"' <<<"$out" || fail "dry run must name the spared mob: $out"
grep -q '^skipped_targets: 1$' <<<"$out" || fail "the zombie beside a name-tagged zombie must be skipped, not killed: $out"
[ "$(sent 'kill')" -eq 0 ] || fail "dry run sent a kill"
[ "$(sent 'tickingarea')" -eq 0 ] || fail "dry run touched ticking areas"
[ "$(sent 'tellraw')" -eq 0 ] || fail "dry run announced"
echo "  ok: dry run prints the plan and sends no kill, ticking area or chat"

# The listing job is the CronJob's template with only the census arguments
# replaced; the sidecar that publishes metrics must be left as it was.
python3 - "$work/state/job-1.json" <<'PY' || fail "the listing job was not built from the CronJob template as intended"
import json, sys
containers = {c["name"]: c for c in json.load(open(sys.argv[1]))["spec"]["template"]["spec"]["containers"]}
args = containers["census"]["args"]
assert args[-3:] == ["-list", "-types", "enderman,zombie"], args
assert "-metrics-file" not in args, "a listing run must not publish metrics: %r" % args
assert containers["metrics-publish"]["args"] == ["keep"], "another container was rewritten"
PY
echo "  ok: the listing job changes only the census arguments"

# --- a real run -----------------------------------------------------------
FAKE_KILLED="Zombie, Zombie" run bash "$mc" cull --types enderman,zombie --confirm
[ "$rc" -eq 0 ] || fail "a run that removed every target must exit 0, got $rc: $out"
grep -q '^remaining: 0$' <<<"$out" || fail "a clean run must report nothing remaining: $out"
grep -q '^ticking_areas_left: 0$' <<<"$out" || fail "a clean run must state it left no ticking area: $out"
[ "$(areas_left)" -eq 0 ] || fail "ticking areas were left on the server: $(cat "$work/state/areas")"
[ "$(sent 'tellraw')" -eq 1 ] || fail "a real run must announce once"
# Scoped by volume and by dimension: a bare @e[type=...] ignores `execute in`
# and reaches every loaded dimension.
grep -q '^execute in the_end run kill @e\[type=enderman,x=-3040,y=-64,z=-640,dx=79,dy=384,dz=79\]$' "$work/sent" \
  || fail "the End kill is not scoped to its padded box: $(grep kill "$work/sent")"
grep -q '^execute in the_end run tickingarea add -3040 0 -640 -2961 0 -561 mccull' "$work/sent" \
  || fail "the End ticking area does not cover the mob's chunk padded by two: $(grep 'tickingarea add' "$work/sent")"
grep 'kill @e' "$work/sent" | grep -v -q ',x=.*,dx=' && fail "a kill was sent without a volume"
grep 'kill @e' "$work/sent" | grep -q 'x=1968\|x=2000' && fail "the box holding a name-tagged zombie was killed in"
first_add="$(grep -n 'tickingarea add' "$work/sent" | head -1 | cut -d: -f1)"
first_kill="$(grep -n 'kill @e' "$work/sent" | head -1 | cut -d: -f1)"
# `run tickingarea remove`, not any remove: the list probe is one too.
first_remove="$(grep -n 'run tickingarea remove' "$work/sent" | head -1 | cut -d: -f1)"
if [ "$first_add" -ge "$first_kill" ] || [ "$first_kill" -ge "$first_remove" ]; then
  fail "the order must be load, kill, unload: add@$first_add kill@$first_kill remove@$first_remove"
fi
echo "  ok: a real run announces, loads, kills by volume, unloads and verifies"

# One area at a time must behave the same: the batch size is the operator's.
MC_CULL_BATCH=1 run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 0 ] || fail "a run with one area at a time failed: $out"
[ "$(sent 'tellraw')" -eq 0 ] || fail "--no-announce still announced"
[ "$(sent 'tickingarea add')" -eq 3 ] || fail "three regions must load three areas, got $(sent 'tickingarea add')"
[ "$(areas_left)" -eq 0 ] || fail "ticking areas were left on the server"
echo "  ok: --no-announce and a batch of one"

# --- targets that survive -------------------------------------------------
cp "$work/fx/listing-2.ndjson" "$work/fx/listing-2.clean"
python3 - "$work/fx/listing-2.ndjson" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
rows.append({"identifier": "zombie", "dimension": "overworld", "x": 700.5, "y": 70, "z": 700.5, "persistent": False})
rows[0]["entities"] = len(rows) - 1
open(sys.argv[1], "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 1 ] || fail "a run that left a target must exit 1, got $rc: $out"
grep -q '^remaining: 1$' <<<"$out" || fail "the surviving target must be counted: $out"
grep -q 'zombie overworld x=700' <<<"$out" || fail "the surviving target must be located: $out"
[ "$(areas_left)" -eq 0 ] || fail "ticking areas were left after an incomplete run"
mv "$work/fx/listing-2.clean" "$work/fx/listing-2.ndjson"
echo "  ok: a surviving target is reported with its position and a non-zero exit"

# --- nothing left force-loaded, whatever goes wrong -------------------------
FAKE_FAIL_ON="kill @e" run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 1 ] || fail "a run whose console dropped mid-batch must exit 1, got $rc: $out"
[ "$(sent 'tickingarea add')" -ge 1 ] || fail "the failure was not mid-batch: no area had been added"
[ "$(areas_left)" -eq 0 ] || fail "a run that died mid-batch left ticking areas: $(cat "$work/state/areas")"
echo "  ok: a run that fails mid-batch unloads what it loaded"

# Stopped from outside while the areas are loading. The wait is long enough
# for the signal to land inside it, which is where a real run spends its time.
rm -rf "$work/state"; mkdir -p "$work/state"; : > "$work/sent"
env PATH="$work/bin:$PATH" CAPTURE="$work/sent" STATE="$work/state" FIXTURES="$work/fx" \
  MC_NAMESPACE=test-ns MC_CULL_LOAD_WAIT=3 MC_CULL_KILL_GAP=0 MC_CULL_POLL=0 MC_CULL_REPLY_POLL=0 \
  bash "$mc" cull --types enderman,zombie --confirm --no-announce > "$work/interrupted" 2>&1 &
pid=$!
for _ in $(seq 1 100); do
  [ -s "$work/state/areas" ] && break
  sleep 0.1
done
[ -s "$work/state/areas" ] || fail "the run never loaded an area to be interrupted in"
kill -TERM "$pid"
rc=0; wait "$pid" || rc=$?
[ "$rc" -ne 0 ] || fail "an interrupted run exited 0: $(cat "$work/interrupted")"
grep -q 'interrupted' "$work/interrupted" || fail "an interrupted run must say so: $(cat "$work/interrupted")"
[ "$(areas_left)" -eq 0 ] || fail "an interrupted run left ticking areas: $(cat "$work/state/areas")"
[ "$(sent 'kill @e')" -eq 0 ] || fail "an interrupted run went on to kill"
echo "  ok: a run stopped by a signal unloads its areas and exits non-zero"

FAKE_STUCK=mccull0 run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 1 ] || fail "an area that will not unload must fail the run, got $rc: $out"
grep -q 'mccull0' <<<"$out" || fail "the stuck area must be named: $out"
grep -q '^hint:' <<<"$out" || fail "a stuck area must come with a next step: $out"
echo "  ok: an area that will not unload is named and fails the run"

# A server that stops answering after the areas were loaded: "none listed"
# read off no reply at all would be a pass for a run that verified nothing.
FAKE_SILENT=1 run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 1 ] || fail "a server that does not answer the list must fail the run, got $rc: $out"
grep -q 'did not answer' <<<"$out" || fail "an unanswered list must be reported as unanswered: $out"
[ "$(sent 'kill')" -eq 0 ] || fail "mobs were killed although the server never reported its ticking areas"
echo "  ok: an unanswered ticking-area list is a failure, not an empty list"

FAKE_FOREIGN_AREAS=8 run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 1 ] || fail "a server with too few free ticking areas must be refused, got $rc: $out"
[ "$(sent 'tickingarea add')" -eq 0 ] || fail "areas were added although too few were free"
[ "$(sent 'kill')" -eq 0 ] || fail "mobs were killed although the run was refused"
echo "  ok: too few free ticking areas refuses before anything is loaded"

# --- listings that must not be acted on -------------------------------------
cp "$work/fx/listing-1.ndjson" "$work/fx/listing-1.keep"
# With the census's own stderr notice ahead of the header, as a job log
# carries it: the refusal has to be about the archive, not about a line that
# is not JSON.
{ echo "census: no snapshot in /snapshot; reading the newest archive instead"
  sed 's/"source":"snapshot"/"source":"archive"/' "$work/fx/listing-1.keep"; } > "$work/fx/listing-1.ndjson"
run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 1 ] || fail "a listing from an archive must be refused, got $rc: $out"
grep -q 'came from archive' <<<"$out" || fail "an archive listing must be refused as one: $out"
[ "$(sent 'kill')" -eq 0 ] || fail "mobs were killed from a stale listing"
cp "$work/fx/listing-1.keep" "$work/fx/listing-1.ndjson"

sed -i '$d' "$work/fx/listing-1.ndjson"
run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 1 ] || fail "a listing shorter than its header says must be refused, got $rc: $out"
grep -q 'cut short' <<<"$out" || fail "a cut listing must be called that: $out"
[ "$(sent 'kill')" -eq 0 ] || fail "mobs were killed from a cut listing"
cp "$work/fx/listing-1.keep" "$work/fx/listing-1.ndjson"
echo "  ok: an archive listing and a cut listing are refused"

FAKE_JOB_FAILS=1 run bash "$mc" cull --types enderman,zombie --dry-run
[ "$rc" -eq 1 ] || fail "a failed listing job must fail the command, got $rc: $out"
grep -q 'flag provided but not defined' <<<"$out" || fail "the job's own error must be shown: $out"
grep -q '^hint:' <<<"$out" || fail "a failed listing job must come with a next step: $out"
[ "$(sent 'delete job')" -ge 1 ] || fail "the failed listing job was not cleaned up"
echo "  ok: a failed listing job is reported with its error and removed"

echo "PASS"
