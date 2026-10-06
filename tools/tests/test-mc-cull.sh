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
    date +%s > "$STATE/unloaded-at"
    printf '%s INFO] Removed ticking area(s)\n- %s: 0 0 0 to 15 0 15\n%s/10 ticking areas in use.\n' "$stamp" "$name" "$(in_use)" >> "$console"
  else
    printf "%s ERROR] No ticking areas named %s exist in the current dimension.\nFailed to execute 'tickingarea' as [Null]\n" "$stamp" "$name" >> "$console"
  fi
}
case "$1" in
  get)
    case "$*" in
      *"get jobs"*)
        n="$(cat "$STATE/job-lists" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$STATE/job-lists"
        # Always there, and never a reason to wait: a backup that finished, a
        # job that is running but does not touch the save, and another
        # release's backup.
        printf '%s-backup-29000001\t\n%s-map-render\t1\nother-release-backup-29000002\t1\n' "$RELEASE_NAME" "$RELEASE_NAME"
        if [ -n "${FAKE_HOLDER:-}" ] && [ "$n" -ge "${FAKE_HOLDER_FROM:-1}" ] && [ "$n" -le "${FAKE_HOLDER_UNTIL:-999999}" ]; then
          printf '%s-%s\t1\n' "$RELEASE_NAME" "$FAKE_HOLDER"
        fi ;;
      *"get job"*succeeded*) [ -n "${FAKE_JOB_FAILS:-}" ] || printf 1 ;;
      *"get job"*failed*)    [ -n "${FAKE_JOB_FAILS:-}" ] && printf 1 ;;
      *) printf 'server-0' ;;
    esac ;;
  create)
    printf '%s' '{"metadata":{"name":"listing"},"spec":{"template":{"spec":{"containers":[{"name":"metrics-publish","args":["keep"]},{"name":"census","args":["-world-dir","/snapshot","-metrics-file","/tmp/metrics.txt"]}]}}}}' ;;
  apply)
    n="$(cat "$STATE/listings" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$STATE/listings"
    # The real server writes an unloaded chunk out over the next few seconds:
    # a snapshot taken sooner than that after an unload is the save as it was
    # before the kills.
    if [ -n "${FAKE_SAVE_LAG:-}" ] && [ -e "$STATE/unloaded-at" ] \
      && [ $(( $(date +%s) - $(cat "$STATE/unloaded-at") )) -lt "$FAKE_SAVE_LAG" ]; then
      touch "$STATE/stale-$n"
    fi
    while [ $# -gt 0 ]; do [ "$1" = "-f" ] && cp "$2" "$STATE/job-$n.json"; shift; done ;;
  delete) printf 'delete %s\n' "$*" >> "$CAPTURE" ;;
  logs)
    case "$*" in
      *job/*)
        [ -n "${FAKE_JOB_FAILS:-}" ] && { echo "census: parse flags: flag provided but not defined: -list"; exit 0; }
        if [ -e "$STATE/stale-$(cat "$STATE/listings")" ]; then
          cat "$FIXTURES/listing-1.ndjson"
        else
          cat "$FIXTURES/listing-$(cat "$STATE/listings").ndjson"
        fi
        [ "${FAKE_LOGS_FAIL_ON:-}" = "$(cat "$STATE/listings")" ] && exit 1 ;;
      *)
        printf 'noise \x00 binary\n'
        [ -n "${FAKE_KILLED:-}" ] && printf '%s INFO] Killed %s\n' "$stamp" "$FAKE_KILLED"
        [ -n "${FAKE_SILENT:-}" ] && exit 0
        [ -n "${FAKE_SILENT_AFTER_ADD:-}" ] && [ -e "$STATE/added" ] && exit 0
        cat "$console" ;;
    esac ;;
  exec)
    shift; while [[ "$1" != "--" ]]; do shift; done; shift 2
    printf '%s\n' "$*" >> "$CAPTURE"
    # A stream that stays open and says nothing, as a stalled exec does, once
    # an area is loaded: the list probe before that is a remove too.
    [ -n "${FAKE_HANG_ON:-}" ] && [ -e "$STATE/added" ] && [[ "$*" == *"$FAKE_HANG_ON"* ]] && exec sleep 30
    [ -n "${FAKE_FAIL_ON:-}" ] && [[ "$*" == *"$FAKE_FAIL_ON"* ]] && exit 1
    if [[ "$*" =~ ^execute\ in\ ([a-z_]+)\ run\ tickingarea\ add\ .*\ ([a-z0-9]+)$ ]]; then
      echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}" >> "$state"
      touch "$STATE/added"
      printf '%s INFO] Added ticking area from 0, 0, 0 to 15, 0, 15.\n%s/10 ticking areas in use.\n' "$stamp" "$(in_use)" >> "$console"
    elif [[ "$*" =~ ^execute\ in\ ([a-z_]+)\ run\ tickingarea\ remove\ ([a-z0-9]+)$ ]]; then
      [ -n "${FAKE_REMOVE_DELAY:-}" ] && sleep "$FAKE_REMOVE_DELAY"
      remove "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ "$*" =~ ^tickingarea\ remove\ ([a-z0-9]+)$ ]]; then
      # The console sits in the overworld.
      remove overworld "${BASH_REMATCH[1]}"
    elif [[ "$*" == "tickingarea list all-dimensions" ]]; then
      # A byte that is not text in any encoding, inside the reply itself.
      junk=""; [ -n "${FAKE_BINARY_REPLY:-}" ] && junk=$'\xff'
      if [ "$(in_use)" -eq 0 ]; then
        printf '%s ERROR] %sNo ticking areas exist in any dimension.\n' "$stamp" "$junk" >> "$console"
      else
        printf '%s INFO] %s§aList of all ticking areas in all dimensions\nOverworld: \n' "$stamp" "$junk" >> "$console"
        while read -r _ name; do echo "- $name: 0 0 0 to 15 0 15$junk"; done < "$state" >> "$console"
        printf '%s/10 ticking areas in use.%s\n%s INFO] Gametime is 563808326\n' "$(in_use)" "$junk" "$stamp" >> "$console"
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
    RELEASE_NAME=fwb MC_RELEASE=fwb MC_NAMESPACE=test-ns MC_CULL_LOAD_WAIT=0 MC_CULL_KILL_GAP=0 MC_CULL_SETTLE_WAIT="${MC_CULL_SETTLE_WAIT:-0}" MC_CULL_POLL=0 MC_CULL_REPLY_POLL=0 "$@" 2>&1)" || rc=$?
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

# One spelling per option, and no option the usage text does not list.
run bash "$mc" cull --types=zombie --dry-run
[ "$rc" -eq 2 ] || fail "--types=<list> must be refused, got $rc: $out"
run bash "$mc" cull --types zombie --dry-run --announce "hello"
[ "$rc" -eq 2 ] || fail "--announce <text> must be refused, got $rc: $out"
[ ! -e "$work/state/listings" ] || fail "a refused cull took a snapshot"
echo "  ok: --types=<list> and --announce <text> are not accepted"

# Zero areas at a time would loop for ever without killing anything.
for batch in 0 11 four; do
  MC_CULL_BATCH="$batch" run bash "$mc" cull --types zombie --confirm
  [ "$rc" -eq 2 ] || fail "MC_CULL_BATCH=$batch must be a usage error, got $rc: $out"
  grep -q 'MC_CULL_BATCH' <<<"$out" || fail "a refused batch size must be named: $out"
  [ ! -s "$work/sent" ] || fail "MC_CULL_BATCH=$batch reached the server: $(cat "$work/sent")"
  [ ! -e "$work/state/listings" ] || fail "MC_CULL_BATCH=$batch took a snapshot"
done
echo "  ok: a batch size outside 1..10 is a usage error"

# --- another holder of the server's save -----------------------------------
for holder in backup-29000100 census-29000100 version-check-29000100 scheduled-restart-29000100 census-list-1006033000; do
  FAKE_HOLDER="$holder" run bash "$mc" cull --types enderman,zombie --confirm
  [ "$rc" -eq 1 ] || fail "a cull started while $holder is active must be refused with 1, got $rc: $out"
  grep -q "fwb-$holder" <<<"$out" || fail "the active job must be named: $out"
  [ ! -e "$work/state/listings" ] || fail "a snapshot was taken while $holder held the save"
  [ ! -s "$work/sent" ] || fail "something was sent while $holder held the save: $(cat "$work/sent")"
done
echo "  ok: an active backup, census, version check or restart refuses the run before anything is sent"

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

# A backup that starts during the kills: the second listing waits it out.
# The first job list is the one before the first listing.
FAKE_HOLDER=backup-29000100 FAKE_HOLDER_FROM=2 FAKE_HOLDER_UNTIL=4 \
  run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 0 ] || fail "a run whose verdict listing had to wait for a backup must still finish, got $rc: $out"
grep -q '^remaining: 0$' <<<"$out" || fail "the verdict must be given once the backup has finished: $out"
[ "$(cat "$work/state/job-lists")" -eq 5 ] || fail "the verdict listing must be taken only once no holder is active, after 5 looks, got $(cat "$work/state/job-lists")"
[ "$(cat "$work/state/listings")" -eq 2 ] || fail "the verdict listing was not taken"
echo "  ok: the verdict listing waits for a backup to finish"

FAKE_HOLDER=backup-29000100 FAKE_HOLDER_FROM=2 MC_CULL_JOB_TIMEOUT=3 \
  run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 1 ] || fail "a verdict listing that could never be taken must fail the run, got $rc: $out"
grep -q 'kills were done but could not be verified' <<<"$out" || fail "the run must say the kills happened unverified: $out"
grep -q 'fwb-backup-29000100' <<<"$out" || fail "the job that held the save must be named: $out"
[ "$(cat "$work/state/listings")" -eq 1 ] || fail "a second snapshot was taken under an active backup"
[ "$(areas_left)" -eq 0 ] || fail "ticking areas were left on the server"
echo "  ok: a backup that never finishes fails the run as done but unverified"

# One area at a time must behave the same: the batch size is the operator's.
MC_CULL_BATCH=1 run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 0 ] || fail "a run with one area at a time failed: $out"
[ "$(sent 'tellraw')" -eq 0 ] || fail "--no-announce still announced"
[ "$(sent 'tickingarea add')" -eq 3 ] || fail "three regions must load three areas, got $(sent 'tickingarea add')"
[ "$(areas_left)" -eq 0 ] || fail "ticking areas were left on the server"
echo "  ok: --no-announce and a batch of one"

# The save lags the unload by a few seconds on the real server. A verdict
# taken from a snapshot inside that lag counts mobs that are already dead.
FAKE_SAVE_LAG=2 MC_CULL_SETTLE_WAIT=2 run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 0 ] || fail "a run whose kills all landed must not fail on a save that had not caught up, got $rc: $out"
grep -q '^remaining: 0$' <<<"$out" || fail "the verdict must be read once the save holds the kills: $out"
echo "  ok: the verdict waits for the save to catch up with the kills"

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
# Counted separately from the exit code: every mob of a planned type inside
# a planned box now. Here that is the survivor alone; the zombie that
# spawned at x=55 stands outside the box around x=10, which ends at x=47.
grep -q '^in_kill_boxes_now: 1$' <<<"$out" || fail "mobs of a planned type inside a planned box must be reported: $out"
grep -q 'zombie overworld x=700' <<<"$out" || fail "the surviving target must be located: $out"
[ "$(areas_left)" -eq 0 ] || fail "ticking areas were left after an incomplete run"
echo "  ok: a surviving target is reported with its position and a non-zero exit"

# The same survivor, behind a verdict listing that cannot be trusted. Each of
# these read as `remaining: 0` when the second listing was only counted.
cp "$work/fx/listing-2.ndjson" "$work/fx/listing-2.survivor"
sed -i '$d' "$work/fx/listing-2.ndjson"
run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 1 ] || fail "a cut verdict listing must fail the run, got $rc: $out"
grep -q 'kills were done but could not be verified' <<<"$out" || fail "a cut verdict listing must be reported as unverified: $out"
grep -q 'cut short' <<<"$out" || fail "a cut verdict listing must be called that: $out"
grep -q '^remaining:' <<<"$out" && fail "a verdict was given from a cut listing: $out"

{ echo "census: no snapshot in /snapshot; reading the newest archive instead"
  sed 's/"source": *"snapshot"/"source":"archive"/' "$work/fx/listing-2.survivor"; } > "$work/fx/listing-2.ndjson"
run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 1 ] || fail "an archive verdict listing must fail the run, got $rc: $out"
grep -q 'kills were done but could not be verified' <<<"$out" || fail "an archive verdict listing must be reported as unverified: $out"
grep -q 'came from archive' <<<"$out" || fail "an archive verdict listing must be called that: $out"
grep -q '^remaining:' <<<"$out" && fail "a verdict was given from an archive listing: $out"

head -1 "$work/fx/listing-2.clean" | sed 's/"entities":3/"entities":0/' > "$work/fx/listing-2.ndjson"
run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 0 ] || fail "a verdict listing that truly lists nothing must pass, got $rc: $out"

# The log stream breaking after the last line it delivered.
cp "$work/fx/listing-2.clean" "$work/fx/listing-2.ndjson"
FAKE_LOGS_FAIL_ON=2 run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 1 ] || fail "a verdict whose job log could not be read must fail the run, got $rc: $out"
grep -q 'kills were done but could not be verified' <<<"$out" || fail "an unread verdict log must be reported as unverified: $out"
[ "$(sent 'delete job')" -ge 2 ] || fail "the listing job whose log could not be read was not cleaned up"
echo "  ok: a cut, archive or unread verdict listing fails the run as done but unverified"

# --- nothing left force-loaded, whatever goes wrong -------------------------
FAKE_FAIL_ON="kill @e" run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 1 ] || fail "a run whose console dropped mid-batch must exit 1, got $rc: $out"
[ "$(sent 'tickingarea add')" -ge 1 ] || fail "the failure was not mid-batch: no area had been added"
[ "$(areas_left)" -eq 0 ] || fail "a run that died mid-batch left ticking areas: $(cat "$work/state/areas")"
echo "  ok: a run that fails mid-batch unloads what it loaded"

# The same failure, with every remove the unload then sends stalling for 30
# seconds. One area in three dimensions and the list probe are four console
# commands: at a one-second limit each the run is over in a few seconds, and
# it must not claim an unload it could not see.
SECONDS=0
MC_CULL_BATCH=1 MC_CULL_CALL_TIMEOUT=1 FAKE_FAIL_ON="kill @e" FAKE_HANG_ON="tickingarea remove" \
  run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$SECONDS" -lt 20 ] || fail "an unload whose console commands stall must be cut short, took ${SECONDS}s: $out"
[ "$rc" -eq 1 ] || fail "a run whose unload stalled must exit 1, got $rc: $out"
grep -q 'could not confirm the ticking areas were unloaded' <<<"$out" || fail "a stalled unload must be reported as unconfirmed: $out"
grep -q '^hint:.*tickingarea list all-dimensions' <<<"$out" || fail "a stalled unload must come with the check to run by hand: $out"
[ "$(areas_left)" -eq 1 ] || fail "the fake was meant to keep the area whose removes stalled, got $(areas_left)"
echo "  ok: a console that stalls during the unload ends the run as unconfirmed"

# Without the command that enforces that limit the run is refused up front.
mkdir -p "$work/no-timeout"
for tool in bash basename python3 mktemp; do ln -sf "$(command -v "$tool")" "$work/no-timeout/$tool"; done
ln -sf "$work/bin/kubectl" "$work/no-timeout/kubectl"
rm -rf "$work/state"; mkdir -p "$work/state"; : > "$work/sent"
rc=0
out="$(env -i PATH="$work/no-timeout" CAPTURE="$work/sent" STATE="$work/state" FIXTURES="$work/fx" \
  bash "$mc" cull --types zombie --confirm 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "a cull without the timeout command must be refused with 1, got $rc: $out"
grep -q 'timeout command is required' <<<"$out" || fail "the missing command must be named: $out"
[ ! -s "$work/sent" ] || fail "a cull without the timeout command reached the server: $(cat "$work/sent")"
[ ! -e "$work/state/listings" ] || fail "a cull without the timeout command took a snapshot"
echo "  ok: a missing timeout command refuses the run before anything is sent"

# Stopped from outside while the areas are loading. The wait is long enough
# for the signal to land inside it, which is where a real run spends its time.
#
# Started through python so that SIGINT is at its default: a background job
# of a script inherits it ignored, and a shell cannot trap what it inherited
# ignored.
#
# With a third argument the signal is sent again once the unload has begun,
# and each remove is slowed so that it lands while areas are still loaded.
interrupt() {
  rm -rf "$work/state"; mkdir -p "$work/state"; : > "$work/sent"
  env PATH="$work/bin:$PATH" CAPTURE="$work/sent" STATE="$work/state" FIXTURES="$work/fx" FAKE_REMOVE_DELAY="${3:+0.3}" \
    RELEASE_NAME=fwb MC_RELEASE=fwb MC_NAMESPACE=test-ns MC_CULL_LOAD_WAIT=3 MC_CULL_KILL_GAP=0 MC_CULL_SETTLE_WAIT=0 MC_CULL_POLL=0 MC_CULL_REPLY_POLL=0 \
    python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
    bash "$mc" cull --types enderman,zombie --confirm --no-announce > "$work/interrupted" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do
    [ -s "$work/state/areas" ] && break
    sleep 0.1
  done
  [ -s "$work/state/areas" ] || fail "the run never loaded an area to be interrupted in"
  kill "-$1" "$pid"
  if [ -n "${3:-}" ]; then
    for _ in $(seq 1 100); do
      grep -q 'interrupted' "$work/interrupted" && break
      sleep 0.1
    done
    [ "$(areas_left)" -gt 0 ] || fail "the unload finished before a second signal could land in it"
    kill "-$1" "$pid"
  fi
  rc=0; wait "$pid" || rc=$?
  [ "$rc" -eq "$2" ] || fail "a run stopped by SIG$1 must exit $2, got $rc: $(cat "$work/interrupted")"
  grep -q 'interrupted' "$work/interrupted" || fail "an interrupted run must say so: $(cat "$work/interrupted")"
  [ "$(areas_left)" -eq 0 ] || fail "a run stopped by SIG$1 left ticking areas: $(cat "$work/state/areas")"
  [ "$(sent 'kill @e')" -eq 0 ] || fail "a run stopped by SIG$1 went on to kill"
}
interrupt TERM 143
interrupt INT 130
echo "  ok: a run stopped by SIGTERM or SIGINT unloads its areas and exits 143 or 130"

interrupt TERM 143 again
interrupt INT 130 again
echo "  ok: a second signal during the unload does not abandon it"

FAKE_STUCK=mccull0 run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 1 ] || fail "an area that will not unload must fail the run, got $rc: $out"
grep -q 'mccull0' <<<"$out" || fail "the stuck area must be named: $out"
grep -q '^hint:' <<<"$out" || fail "a stuck area must come with a next step: $out"
echo "  ok: an area that will not unload is named and fails the run"

# The same with a byte in the reply that is not text. In a UTF-8 locale a
# grep may then call its input binary and print no matching line, which here
# would read as "no areas left". Which greps do, and for which lines, varies
# by version, so the byte is on every line the tool reads.
FAKE_BINARY_REPLY=1 LC_ALL=C.UTF-8 run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 0 ] || fail "a non-text byte in the ticking-area reply must not stop a clean run, got $rc: $out"
FAKE_BINARY_REPLY=1 FAKE_STUCK=mccull0 LC_ALL=C.UTF-8 run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 1 ] || fail "a stuck area behind a non-text byte must fail the run, got $rc: $out"
grep -q 'ticking areas would not unload: mccull0' <<<"$out" || fail "a stuck area behind a non-text byte must be named: $out"
echo "  ok: a non-text byte in the reply does not hide a ticking area"

# A server that stops answering once the areas are loaded: "none listed" read
# off no reply at all would be a pass for a run that verified nothing.
FAKE_SILENT_AFTER_ADD=1 run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 1 ] || fail "a server that goes silent after loading must fail the run, got $rc: $out"
[ "$(sent 'tickingarea add')" -ge 1 ] || fail "the server was meant to go silent after an area was added"
grep -q 'could not confirm the ticking areas were unloaded' <<<"$out" || fail "an unanswered list after loading must be reported as unconfirmed: $out"
grep -q '^remaining:' <<<"$out" && fail "a verdict was given although the unload was never confirmed: $out"
echo "  ok: a server that goes silent after loading fails the run as unconfirmed"

# A server that never answers at all is refused before anything is loaded.
FAKE_SILENT=1 run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 1 ] || fail "a server that does not answer the list must fail the run, got $rc: $out"
grep -q 'did not answer' <<<"$out" || fail "an unanswered list must be reported as unanswered: $out"
[ "$(sent 'kill')" -eq 0 ] || fail "mobs were killed although the server never reported its ticking areas"
[ "$(sent 'tickingarea add')" -eq 0 ] || fail "areas were loaded although the server never reported its ticking areas"
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

# --- a name-tagged mob near a box, not in it --------------------------------
# The zombie at x=2010.5 has the box x=1968..2047 (its chunk, 2000..2015,
# padded by 32), so the margin of 64 reaches x=2112.
named_near() {
  cat > "$work/fx/listing-1.ndjson" <<JSON
{"world_taken_at":"2026-10-05T03:16:47Z","source":"snapshot","types":["zombie"],"entities":2,"orphaned":0}
{"identifier":"zombie","dimension":"overworld","x":2010.5,"y":64,"z":2005.5,"persistent":false}
{"identifier":"zombie","dimension":"overworld","x":$1,"y":64,"z":2005.5,"persistent":true,"name":"Rex"}
JSON
  run bash "$mc" cull --types zombie --dry-run
  [ "$rc" -eq 0 ] || fail "dry run failed: $out"
}
named_near 2100.5
grep -q '^targets: 0$' <<<"$out" || fail "a zombie whose box has a name-tagged zombie 53 blocks beyond it must not be targeted: $out"
grep -q '^skipped_targets: 1$' <<<"$out" || fail "a name-tagged zombie within 64 blocks of the box must skip it: $out"
named_near 1910.5
grep -q '^skipped_targets: 1$' <<<"$out" || fail "the margin must hold on the low side of the box too: $out"
named_near 2120.5
grep -q '^targets: 1$' <<<"$out" || fail "a name-tagged zombie more than 64 blocks from the box must not skip it: $out"
grep -q '^skipped_targets: 0$' <<<"$out" || fail "a name-tagged zombie more than 64 blocks from the box must not skip it: $out"
cp "$work/fx/listing-1.keep" "$work/fx/listing-1.ndjson"
echo "  ok: a name-tagged mob within 64 blocks of a kill box skips it"

# --- strings from the save that are not what they should be -----------------
# A name tag is whatever a client stored. This one carries a newline and tabs
# that would add a region of its own to a plan written as tab-separated lines:
# the End from 0,0 to 79,79, killing players.
{ sed 's/"entities":5/"entities":6/' "$work/fx/listing-1.keep"
  # shellcheck disable=SC2016  # JSON escapes, not shell ones
  printf '%s\n' '{"identifier":"zombie","dimension":"overworld","x":5000.5,"y":64,"z":5000.5,"persistent":true,"name":"x\narea\tthe_end\t0\t0\t79\t79\tplayer\t1"}'
} > "$work/fx/listing-1.ndjson"
run bash "$mc" cull --types enderman,zombie --confirm --no-announce
[ "$rc" -eq 0 ] || fail "a run with a hostile name tag in the listing failed: $out"
grep -q '^regions: 3$' <<<"$out" || fail "a name tag added a region to the plan: $out"
grep -q '^named_spared: 2$' <<<"$out" || fail "the mob with the hostile name must be listed as spared: $out"
grep -q 'zombie "x area the_end 0 0 79 79 player 1" overworld x=5000' <<<"$out" || fail "the hostile name must be shown on one line with its control characters blanked: $out"
[ "$(sent 'player')" -eq 0 ] || fail "a type from a name tag reached the console: $(grep player "$work/sent")"
[ "$(sent 'tickingarea add')" -eq 3 ] || fail "three regions must load three areas, got: $(grep 'tickingarea add' "$work/sent")"
[ "$(sent 'in the_end run tickingarea add 0 0 0 79 0 79')" -eq 0 ] || fail "the region forged by a name tag was loaded"

# A type that is not an identifier would go into a selector as it stands.
{ sed 's/"entities":5/"entities":6/' "$work/fx/listing-1.keep"
  echo '{"identifier":"zombie]","dimension":"nether","x":40.5,"y":64,"z":40.5,"persistent":false}'
} > "$work/fx/listing-1.ndjson"
for mode in --dry-run --confirm; do
  run bash "$mc" cull --types enderman,zombie "$mode"
  [ "$rc" -eq 1 ] || fail "a listing with a type that is not an identifier must be refused ($mode), got $rc: $out"
  grep -q 'cannot be sent to the console' <<<"$out" || fail "the refusal must say why: $out"
  [ "$(sent 'tickingarea add')" -eq 0 ] || fail "an area was loaded from a listing with a malformed type"
  [ "$(sent 'kill')" -eq 0 ] || fail "a kill was sent from a listing with a malformed type: $(grep kill "$work/sent")"
  [ "$(sent 'tellraw')" -eq 0 ] || fail "a run refused for a malformed type announced itself"
done
cp "$work/fx/listing-1.keep" "$work/fx/listing-1.ndjson"
echo "  ok: a control character in a name and a malformed type cannot shape a console command"

# --- a skipped target standing in a neighbour's box --------------------------
# The two zombies are skipped for Rex, 100 blocks from the second. The
# skeleton's box, x=32..111, is planned and covers the zombie at x=100.5, but
# it kills skeletons only: that zombie staying put is the plan, not a failure.
cp "$work/fx/listing-2.ndjson" "$work/fx/listing-2.keep"
cat > "$work/fx/listing-1.ndjson" <<'JSON'
{"world_taken_at":"2026-10-05T03:16:47Z","source":"snapshot","types":["skeleton","zombie"],"entities":4,"orphaned":0}
{"identifier":"skeleton","dimension":"overworld","x":70.5,"y":64,"z":10.5,"persistent":false}
{"identifier":"zombie","dimension":"overworld","x":100.5,"y":64,"z":10.5,"persistent":true}
{"identifier":"zombie","dimension":"overworld","x":150.5,"y":64,"z":10.5,"persistent":true}
{"identifier":"zombie","dimension":"overworld","x":250.5,"y":64,"z":10.5,"persistent":true,"name":"Rex"}
JSON
grep -v '"identifier":"skeleton"' "$work/fx/listing-1.ndjson" | sed 's/"entities":4/"entities":3/;s/03:16:47/03:46:04/' > "$work/fx/listing-2.ndjson"
run bash "$mc" cull --types skeleton,zombie --confirm --no-announce
grep -q '^skipped_targets: 2$' <<<"$out" || fail "both zombies must be skipped for the name-tagged one: $out"
grep -q '^targets: 1$' <<<"$out" || fail "the skeleton must be the one target: $out"
[ "$(sent 'type=zombie')" -eq 0 ] || fail "a zombie kill was sent although every zombie was skipped"
grep -q '^remaining: 0$' <<<"$out" || fail "a skipped zombie inside the skeleton's box was counted as a surviving target: $out"
[ "$rc" -eq 0 ] || fail "a run that removed its one target must exit 0, got $rc: $out"
# The same box does answer for its own type.
cp "$work/fx/listing-1.ndjson" "$work/fx/listing-2.ndjson"
run bash "$mc" cull --types skeleton,zombie --confirm --no-announce
grep -q '^remaining: 1$' <<<"$out" || fail "a skeleton still in its box must be counted: $out"
[ "$rc" -eq 1 ] || fail "a surviving skeleton must fail the run, got $rc: $out"
cp "$work/fx/listing-1.keep" "$work/fx/listing-1.ndjson"
mv "$work/fx/listing-2.keep" "$work/fx/listing-2.ndjson"
echo "  ok: a skipped target inside a neighbour's box is not a surviving target"

FAKE_JOB_FAILS=1 run bash "$mc" cull --types enderman,zombie --dry-run
[ "$rc" -eq 1 ] || fail "a failed listing job must fail the command, got $rc: $out"
grep -q 'flag provided but not defined' <<<"$out" || fail "the job's own error must be shown: $out"
grep -q '^hint:' <<<"$out" || fail "a failed listing job must come with a next step: $out"
[ "$(sent 'delete job')" -ge 1 ] || fail "the failed listing job was not cleaned up"
echo "  ok: a failed listing job is reported with its error and removed"

echo "PASS"
