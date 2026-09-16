#!/usr/bin/env bash
# Exercises the census snapshotter against a staged world and a fake server.
#
# The contract under test cannot be checked by the thing that consumes it. The
# census reader refuses the half-copies it can see, but a journal truncated part
# way through a copy is byte-for-byte what a journal a live server had only just
# begun looks like -- it scans cleanly, exits 0, and reports itself a fresh
# snapshot. What rules that out is the ordering, world first and marker last,
# plus the size comparison against the length the server committed. This suite
# is the only place either is checked.
#
# The script is extracted from the rendered chart rather than copied here, so
# the test cannot drift away from what actually ships.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/minecraft-fwb"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template minecraft-fwb "$chart" \
  -f "$chart/values.yaml" \
  --set census.enabled=true > "$work/rendered.yaml"

# The snapshotter ships as a ConfigMap the init container mounts, not as an
# inline arg, so it is read from there.
python3 -c "
import sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc.get('kind') == 'ConfigMap' and doc['metadata']['name'].endswith('-census-snapshot'):
        sys.stdout.write(doc['data']['snapshot.sh'])
" "$work/rendered.yaml" > "$work/snapshot.sh"
[ -s "$work/snapshot.sh" ] || fail "could not extract the snapshotter from the chart"

# --- which container the snapshotter talks to --------------------------------
# The server pod runs three containers and kubectl takes the first when none is
# named. That ordering is a property of a vendored subchart plus this chart's
# sidecar list, so the name is checked against the rendered workload rather than
# trusted. Getting it wrong is silent: the manifest poll simply never matches
# and every night falls back to an archive, exit 0.
server_container="$(python3 -c "
import sys, yaml
env = containers = None
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if not doc:
        continue
    if doc.get('kind') == 'CronJob' and doc['metadata']['name'].endswith('-census'):
        env = {e['name']: e.get('value') for e in
               doc['spec']['jobTemplate']['spec']['template']['spec']['initContainers'][0]['env']}
    if doc.get('kind') == 'StatefulSet' and doc['metadata']['name'].endswith('-minecraft-bedrock'):
        containers = [c['name'] for c in doc['spec']['template']['spec']['containers']]
assert env and env.get('SERVER_CONTAINER'), 'the snapshotter names no container'
assert containers, 'no server StatefulSet rendered to check the name against'
assert env['SERVER_CONTAINER'] in containers, \
    f\"SERVER_CONTAINER={env['SERVER_CONTAINER']} is not one of {containers}\"
print(env['SERVER_CONTAINER'])
" "$work/rendered.yaml")" || fail "the snapshotter does not name a container the server pod actually has"
echo "  ok: the snapshotter names a container the server pod actually runs"

# Every call into the server pod names it. An unnamed one reads as working right
# up until a subchart bump moves the game server off index 0. Continuations are
# joined first, in case a call is ever wrapped across lines.
sed -e :a -e '/\\$/N; s/\\\n//; ta' "$work/snapshot.sh" > "$work/snapshot.joined"
calls=0
while read -r line; do
  calls=$((calls + 1))
  # shellcheck disable=SC2016  # matching the extracted script's literal text,
  # not this shell's expansion of it.
  case "$line" in
    *'-c "$SERVER_CONTAINER"'*) ;;
    *) fail "a call into the server pod names no container: $line" ;;
  esac
done < <(grep -E '^[^#]*kubectl (exec|logs) ' "$work/snapshot.joined")
[[ "$calls" -ge 4 ]] || fail "expected at least four exec/log calls to check, found $calls"
echo "  ok: all $calls exec and log calls name their container"

# The census mounts the server's ReadWriteOnce world claim, so it has to land on
# the server's node. A podAffinity whose selector matches no pod is not an
# error -- it is a preference that silently does nothing, which is only visible
# on the night the server's node set is widened and the pod sits in
# ContainerCreating behind a Multi-Attach error.
python3 - "$work/rendered.yaml" <<'AFFINITY' || fail "the census does not prefer the node its world volume is attached to"
import sys, yaml

census = server = None
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if not doc:
        continue
    if doc.get("kind") == "CronJob" and doc["metadata"]["name"].endswith("-census"):
        census = doc["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    if doc.get("kind") == "StatefulSet" and doc["metadata"]["name"].endswith("-minecraft-bedrock"):
        server = doc["spec"]["template"]["metadata"]["labels"]

assert census and server, "census CronJob or server StatefulSet did not render"
affinity = census.get("affinity") or {}
assert "nodeAffinity" in affinity, "the census is not pinned to the world volume's node set"

pod = affinity.get("podAffinity") or {}
terms = pod.get("preferredDuringSchedulingIgnoredDuringExecution") or []
assert terms, "the census expresses no preference for the server's node"
assert "requiredDuringSchedulingIgnoredDuringExecution" not in pod, (
    "a required podAffinity means 'run only if a server pod exists', and the "
    "census still has to read last night's archive on the nights it does not"
)
for t in terms:
    term = t["podAffinityTerm"]
    labels = term["labelSelector"]["matchLabels"]
    assert term["topologyKey"] == "kubernetes.io/hostname", term["topologyKey"]
    unmatched = {k: v for k, v in labels.items() if server.get(k) != v}
    assert not unmatched, (
        f"the podAffinity selector {labels} matches no server pod (its labels "
        f"are {server}), so the preference does nothing at all"
    )
AFFINITY
echo "  ok: the census prefers the server's node with a selector that matches it"

# --- who may write which volume ---------------------------------------------
# The census only reads worlds, but goleveldb opens a database by flocking a
# LOCK file in the db directory and creates that file when it is absent --
# ReadOnly stops it writing the database, not the lock. `save query` never names
# LOCK, so no snapshot ever carries one, and a read-only snapshot mount fails
# the open with EROFS before a record is read. That is invisible to `helm
# template`: both spellings render, and only one of them opens a world.
#
# The inverse matters more: the world mount is the live server's PVC, and the
# census must never be able to write it. So this is a two-sided check, and it is
# run three times -- once against the chart, and once against each of the two
# one-line mutations that would break a side of it.
cat > "$work/check-mounts.py" <<'MOUNTS'
import sys, yaml

census = None
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc.get("kind") == "CronJob" and doc["metadata"]["name"].endswith("-census"):
        census = doc["spec"]["jobTemplate"]["spec"]["template"]["spec"]
assert census, "no census CronJob rendered"

init = {c["name"]: c for c in census.get("initContainers") or []}
main = {c["name"]: c for c in census["containers"]}
assert "snapshot" in init, "the census job runs no snapshot init container"
assert "census" in main, "the census job runs no census container"


def mounts(container):
    return {m["name"]: m for m in container.get("volumeMounts") or []}


# The world is the running server's data. Checked across every container rather
# than on the one that mounts it today, because the failure being prevented is a
# future container mounting it writable, not this one changing.
world_seen = 0
for name, c in list(init.items()) + list(main.items()):
    m = mounts(c).get("world")
    if m is None:
        continue
    world_seen += 1
    assert m.get("readOnly") is True, (
        f"the {name} container mounts the live server's world writable"
    )
assert world_seen == 1, f"expected exactly one container to mount the world, found {world_seen}"

snapshot = mounts(main["census"]).get("snapshot")
assert snapshot, "the census container does not mount the snapshot at all"
assert not snapshot.get("readOnly", False), (
    "the census mounts the snapshot read-only: goleveldb creates a LOCK file in "
    "the db directory it opens, even read-only, and the snapshotter copies only "
    "what save query names -- so this fails the open with EROFS every run"
)

# Writable is only defensible because the volume is per-run scratch that nothing
# outlives. A snapshot backed by a claim would make this a real grant.
volumes = {v["name"]: v for v in census["volumes"]}
assert "emptyDir" in volumes["snapshot"], (
    "the snapshot volume is no longer a per-run emptyDir, so mounting it "
    "writable now grants the census write access to something that survives it"
)

backup = mounts(main["census"]).get("backup")
assert backup and backup.get("readOnly") is True, (
    "the census mounts the archive volume writable; it is the only copy of every "
    "night's backup"
)
MOUNTS

python3 "$work/check-mounts.py" "$work/rendered.yaml" \
  || fail "the census cannot open the snapshot it is given, or it can write something it must not"

# Negative controls. Each flips one field in a copy of the render; a check that
# does not go red on both is asserting nothing.
mutate() {
  python3 - "$work/rendered.yaml" "$1" "$2" <<'MUTATE'
import sys, yaml

src, dst, which = sys.argv[1], sys.argv[2], sys.argv[3]
docs = list(yaml.safe_load_all(open(src)))
touched = 0
for doc in docs:
    if not doc or doc.get("kind") != "CronJob" or not doc["metadata"]["name"].endswith("-census"):
        continue
    spec = doc["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    groups = (spec.get("initContainers") or []) + spec["containers"]
    for c in groups:
        for m in c.get("volumeMounts") or []:
            if which == "snapshot-readonly" and c["name"] == "census" and m["name"] == "snapshot":
                m["readOnly"] = True
                touched += 1
            if which == "world-writable" and m["name"] == "world":
                m.pop("readOnly", None)
                touched += 1
assert touched == 1, f"mutation {which} matched {touched} mounts, so it is not the mutation it claims"
with open(dst, "w") as fh:
    yaml.safe_dump_all(docs, fh)
MUTATE
}

for mutation in snapshot-readonly world-writable; do
  mutate "$work/mutant-$mutation.yaml" "$mutation"
  if python3 "$work/check-mounts.py" "$work/mutant-$mutation.yaml" >/dev/null 2>&1; then
    fail "the mount check passes a render mutated to $mutation, so it checks nothing"
  fi
done
echo "  ok: the census can write its snapshot, cannot write the world or the archives, and the check fails on both mutants"

# The log read is the one call that can block after the hold succeeded: bash
# defers its traps until the foreground child returns, so an unbounded read here
# means activeDeadlineSeconds' SIGTERM never reaches the resume trap and the
# server stays held, persisting nothing, until the next morning.
grep -qE '^[^#]*timeout [0-9]+s kubectl logs ' "$work/snapshot.joined" \
  || fail "the manifest log read is not bounded by a timeout"
if grep -qE '^[^#]*[^s] kubectl logs ' "$work/snapshot.joined"; then
  fail "an unbounded kubectl logs call survives in the snapshotter"
fi
echo "  ok: every log read is bounded by a timeout"

# --- the schedule, and what stops catch-up from undoing it -------------------
# concurrencyPolicy is per-CronJob and cannot see the backup, so two jobs
# holding the same server is prevented by the clock alone -- and only while runs
# start on time. Computed from the values rather than asserted as a literal, so
# moving any of the three schedules fails here rather than silently overlapping.
python3 - "$work/rendered.yaml" "$chart/values.yaml" <<'PY' || fail "the census schedule does not clear the jobs it shares a server with"
import sys, yaml

rendered, valuesfile = sys.argv[1], sys.argv[2]
v = yaml.safe_load(open(valuesfile))

def start_minutes(cron):
    minute, hour = cron.split()[0], cron.split()[1]
    assert minute.isdigit(), f"cannot read a start time from {cron!r}"
    return int(minute) + (0 if hour == "*" else int(hour) * 60)

census = None
for doc in yaml.safe_load_all(open(rendered)):
    if doc and doc.get("kind") == "CronJob" and doc["metadata"]["name"].endswith("-census"):
        census = doc["spec"]

assert census, "no census CronJob rendered"
deadline = census.get("startingDeadlineSeconds")
assert deadline, (
    "startingDeadlineSeconds is unset: after an outage the controller starts "
    "the most recent missed run of every CronJob in one reconcile, and the "
    "backup and the census would both hold the same server"
)

census_start = start_minutes(census["schedule"])

# The backup holds the same server and may run to its activeDeadlineSeconds,
# which is a literal in backup-cronjob.yaml.
backup_end = start_minutes(v["backup"]["schedule"]) + 3600 // 60
# The version check runs hourly and can be restarting the server for its whole
# timeout, so the run landing before the census is what matters.
vc = v["versionCheck"]
vc_len = -(-int(vc["timeoutSeconds"]) // 60)
assert vc["schedule"].split()[1] == "*", "the version check is no longer hourly; recheck this"
vc_end = ((census_start - 1) // 60) * 60 + start_minutes(vc["schedule"]) % 60 + vc_len

for name, end in (("the backup", backup_end), ("the version check", vc_end)):
    assert census_start > end, (
        f"the census starts at {census_start // 60:02d}:{census_start % 60:02d}, "
        f"but {name} can still be driving the server until "
        f"{end // 60:02d}:{end % 60:02d}"
    )

# A deadline longer than the gap to the nearest neighbour lets a late run start
# inside that neighbour's window, which is the overlap the schedule prevents.
gap = (census_start - max(backup_end, vc_end)) * 60
assert deadline <= gap, (
    f"startingDeadlineSeconds={deadline} exceeds the {gap}s gap to the nearest "
    "job holding the same server, so a late run can still start inside it"
)
print(f"    census {census_start // 60:02d}:{census_start % 60:02d}, "
      f"deadline {deadline}s, gap {gap}s")
PY
echo "  ok: the census clears both jobs holding the same server, and cannot catch up into them"

mkdir -p "$work/sa"
echo -n "test-ns" > "$work/sa/namespace"
sed -i "s|/var/run/secrets/kubernetes.io/serviceaccount/namespace|$work/sa/namespace|" "$work/snapshot.sh"
# The world the server would be holding, and the directory it copies into, both
# staged outside the container's own paths so the suite needs no root and no
# volume.
sed -i "s|/data/worlds|$work/worlds|g" "$work/snapshot.sh"
sed -i "s|^OUT=/snapshot$|OUT=$work/snap|" "$work/snapshot.sh"
grep -q "^OUT=$work/snap$" "$work/snapshot.sh" || fail "could not redirect the snapshot directory"

# Static half of the atomicity check, and it has to be static: nothing
# observable at the end of a run distinguishes a marker renamed into place from
# one written there. A marker created under its final name exists while it is
# still empty, and an empty marker is a parse failure that fails the census
# instead of letting it fall back to an archive.
# shellcheck disable=SC2016  # the single quotes are the point: this matches the
# extracted script's literal text, not this shell's expansion of it.
grep -q 'mv "$OUT/.snapshot-taken-at.tmp" "$OUT/snapshot-taken-at"' "$work/snapshot.sh" \
  || fail "the marker is not moved into place from a temporary name"
# shellcheck disable=SC2016
if grep -q '> "$OUT/snapshot-taken-at"' "$work/snapshot.sh"; then
  fail "something redirects straight into the final marker name, which is not atomic"
fi
echo "  ok: the marker is renamed into place rather than written there"

# Stages a world under $work/worlds/FWB/db. Every file is written longer than
# the length the manifest will report, which is what LevelDB does: it keeps
# appending past its committed length, so a copy that does not truncate picks up
# bytes the server had not committed.
stage_world() {
  rm -rf "$work/worlds"
  mkdir -p "$work/worlds/FWB/db"
  printf 'MANIFEST-000005\n' > "$work/worlds/FWB/db/CURRENT"
  head -c 400 /dev/zero | tr '\0' 'M' > "$work/worlds/FWB/db/MANIFEST-000005"
  head -c 2048 /dev/zero | tr '\0' 'L' > "$work/worlds/FWB/db/000006.log"
  head -c 900 /dev/zero | tr '\0' 'D' > "$work/worlds/FWB/db/000007.ldb"
}

# The manifest `save query` prints. Committed lengths are deliberately shorter
# than the files staged above.
MANIFEST_WHOLE='FWB/db/CURRENT:16, FWB/db/MANIFEST-000005:200, FWB/db/000006.log:1024, FWB/db/000007.ldb:512'
# A file the server named and the volume does not hold, ordered so two files are
# already copied when the copy gives up. Every other entry is whole, so what
# this exercises is the abandonment, not a world that would be refused anyway.
MANIFEST_MID_COPY_FAILS='FWB/db/CURRENT:16, FWB/db/MANIFEST-000005:200, FWB/db/000009.ldb:512, FWB/db/000006.log:1024'
# The journal promised longer than the volume holds. `head -c` writes what it
# found and exits 0, so nothing but an explicit size comparison separates this
# from a whole copy: the tree that results has a CURRENT, the manifest CURRENT
# names, four files and a .log journal, which is every structural check there
# is. Left unrefused it publishes, and the report is a confident population
# count for a world that was never whole.
MANIFEST_SHORT_READ='FWB/db/CURRENT:16, FWB/db/MANIFEST-000005:200, FWB/db/000006.log:99999, FWB/db/000007.ldb:512'
# Two files, so the copy is clean but the manifest is too thin to be a world.
MANIFEST_TOO_FEW='FWB/db/CURRENT:16, FWB/db/MANIFEST-000005:200'

mkdir -p "$work/bin"
cat > "$work/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
# Every call is checked for the container flag before it is answered: a shim
# that happily serves an unnamed exec would make the static check above the only
# thing standing between this job and containers[0].
case "$*" in
  exec*|logs*)
    [[ "$*" == *"-c $SERVER_CONTAINER"* ]] || {
      echo "shim: call into the pod named no container: $*" >&2
      exit 64
    }
    ;;
esac
# Records what the snapshot directory looked like at the moment the server was
# resumed. The snapshotter resumes from its EXIT trap, so a marker present here
# means the world was copied and published while the server was still held --
# and a marker absent here on a failing case means nothing was published at all.
if [[ "$*" == *"send-command save resume"* ]]; then
  {
    echo "resumed"
    echo "files=$(find "$SNAPSHOT_DIR" -type f ! -name 'snapshot-taken-at' 2>/dev/null | wc -l)"
    [[ -e "$SNAPSHOT_DIR/snapshot-taken-at" ]] && echo "marker_present_at_resume"
    [[ -e "$SNAPSHOT_DIR/.snapshot-taken-at.tmp" ]] && echo "tmp_marker_present_at_resume"
  } >> "$AUDIT"
  exit 0
fi
if [[ "$*" == *"send-command save hold"* ]]; then
  [[ "${FAKE_HOLD:-ok}" == "fail" ]] && exit 1
  exit 0
fi
if [[ "$*" == *"send-command save query"* ]]; then
  exit 0
fi
if [[ "$1" == "get" ]]; then
  [[ "$*" == *"status.phase"* ]] && { printf '%s' "${FAKE_PHASE:-Running}"; exit 0; }
  [[ "$*" == *"Ready"* ]] && { printf '%s' "${FAKE_READY:-True}"; exit 0; }
  exit 0
fi
if [[ "$1" == "logs" ]]; then
  printf 'Data saved. Files are now ready to be copied.\n%s\n' "${FAKE_MANIFEST:-}"
  exit 0
fi
exit 0
SHIM
chmod +x "$work/bin/kubectl"

# Bounded, because the failure shape this guards against is a hang: the manifest
# poll is thirty iterations of sleep plus a bounded exec, so a shim that stops
# answering costs two and a half minutes per case rather than a failure. Every
# case here is meant to finish in seconds.
run() {
  snap="$work/snap"
  audit="$work/audit"
  rm -rf "$snap" "$audit"
  mkdir -p "$snap"
  timeout 120 env PATH="$work/bin:$PATH" \
      SERVER_POD=server-0 SERVER_CONTAINER="$server_container" \
      SNAPSHOT_DIR="$snap" AUDIT="$audit" \
      bash "$work/snapshot.sh" 2>&1
}

stage_world

# --- the happy path, and the ordering that makes it trustworthy -------------
out="$(FAKE_MANIFEST="$MANIFEST_WHOLE" run)" || fail "a whole snapshot exited non-zero: $out"
[[ -f "$work/snap/snapshot-taken-at" ]] || fail "no marker after a successful hold"
grep -q "resumed" "$work/audit" || fail "the server was never resumed"
grep -q "files=4" "$work/audit" \
  || fail "the world was not fully copied before the server resumed: $(cat "$work/audit")"
grep -q "marker_present_at_resume" "$work/audit" \
  || fail "the marker was published after the server resumed, so it vouches for a world the server could have been writing"
if grep -q "tmp_marker_present_at_resume" "$work/audit"; then
  fail "the temporary marker was left behind"
fi
[[ -e "$work/snap/.snapshot-taken-at.tmp" ]] && fail "the temporary marker survived a successful run"
echo "  ok: the world is copied and the marker published while the server is still held"

# The marker must be the newest thing in the directory. Compared with fractional
# seconds, because a copy this small finishes inside one second and a
# whole-second comparison would pass on any ordering at all.
marker_mtime="$(stat -c %.Y "$work/snap/snapshot-taken-at")"
while read -r f; do
  m="$(stat -c %.Y "$f")"
  awk -v a="$marker_mtime" -v b="$m" 'BEGIN { exit !(a >= b) }' \
    || fail "the marker is older than $f"
done < <(find "$work/snap" -type f ! -name 'snapshot-taken-at')
echo "  ok: the marker is newer than every file it vouches for"

# Provenance has to parse as RFC3339 and describe a capture that has happened;
# the reader refuses a marker it cannot parse rather than falling back.
stamp="$(cat "$work/snap/snapshot-taken-at")"
python3 - "$stamp" <<'PY' || fail "the marker is not a usable RFC3339 stamp: $stamp"
import datetime, sys
t = datetime.datetime.strptime(sys.argv[1].strip(), "%Y-%m-%dT%H:%M:%SZ").replace(
    tzinfo=datetime.timezone.utc)
now = datetime.datetime.now(datetime.timezone.utc)
assert t <= now + datetime.timedelta(minutes=5), "marker is ahead of the clock"
assert t >= now - datetime.timedelta(minutes=5), "marker is implausibly old"
PY
echo "  ok: the marker carries a parsable, present-tense capture time"

# --- truncation to the committed length -------------------------------------
[[ "$(stat -c %s "$work/snap/FWB/db/000006.log")" == "1024" ]] \
  || fail "the journal was not truncated to its committed length"
[[ "$(stat -c %s "$work/snap/FWB/db/MANIFEST-000005")" == "200" ]] \
  || fail "the manifest was not truncated to its committed length"
echo "  ok: every file is truncated to the length save query reported"

# --- no hold, no snapshot ---------------------------------------------------
# The census falls back to last night's archive on its own, so this must exit 0
# and leave nothing marked. Failing here would stop the census running at all.
out="$(FAKE_HOLD=fail FAKE_MANIFEST="$MANIFEST_WHOLE" run)" || fail "a missed hold exited non-zero: $out"
[[ -f "$work/snap/snapshot-taken-at" ]] && fail "a marker was written without a hold"
left="$(find "$work/snap" -mindepth 1 | wc -l)"
[[ "$left" -eq 0 ]] || fail "a failed hold left $left entries behind"
grep -q "resumed" "$work/audit" || fail "the server was not resumed after a failed hold"
echo "  ok: a failed hold writes no marker, leaves no directory, resumes the server, and exits 0"

# An unreachable server is the same answer, reached earlier.
out="$(FAKE_READY=False FAKE_MANIFEST="$MANIFEST_WHOLE" run)" || fail "an unready server exited non-zero: $out"
[[ -f "$work/snap/snapshot-taken-at" ]] && fail "a marker was written for an unready server"
echo "  ok: an unready server writes no marker and exits 0"

# --- a manifest too thin to be a world --------------------------------------
out="$(FAKE_MANIFEST="$MANIFEST_TOO_FEW" run)" || fail "a two-file manifest exited non-zero: $out"
[[ -f "$work/snap/snapshot-taken-at" ]] && fail "a two-file world was marked as a snapshot"
left="$(find "$work/snap" -type f | wc -l)"
[[ "$left" -eq 0 ]] || fail "a refused manifest left $left files behind for the census to read"
echo "  ok: a manifest naming too few files is not marked"

# --- the copy giving up part way through ------------------------------------
# The world is half in the directory when this fails, which is the state the
# marker ordering exists for: nothing downstream could tell that tree from a
# whole one. What has to be true afterwards is that the run ends quietly with
# the volume empty and the server writing again.
out="$(FAKE_MANIFEST="$MANIFEST_MID_COPY_FAILS" run)" || fail "a failed copy exited non-zero: $out"
[[ -f "$work/snap/snapshot-taken-at" ]] && fail "a copy that gave up part way through was marked as a snapshot"
if grep -q "marker_present_at_resume" "$work/audit"; then
  fail "a marker existed when the server resumed after a failed copy"
fi
left="$(find "$work/snap" -type f | wc -l)"
[[ "$left" -eq 0 ]] || fail "a copy that gave up left $left files behind for the census to read"
grep -q "resumed" "$work/audit" || fail "the server was not resumed after a failed copy"
grep -q "read the newest archive instead" <<<"$out" \
  || fail "a failed copy said nothing about falling back: $out"
echo "  ok: a copy that gives up part way through leaves nothing and resumes the server"

# --- a source shorter than the length the server committed -------------------
# Nothing structural is wrong with what this produces: four files, a CURRENT,
# the manifest it names, a .log journal. Every check the snapshotter and the
# reader share passes, so this is refused by comparing the copied size against
# the committed length or it is not refused at all.
out="$(FAKE_MANIFEST="$MANIFEST_SHORT_READ" run)" || fail "a short read exited non-zero: $out"
[[ -f "$work/snap/snapshot-taken-at" ]] && fail "a file copied short of its committed length was marked as a snapshot"
grep -q "copied short of the 99999 bytes" <<<"$out" \
  || fail "a short read was not reported as one: $out"
left="$(find "$work/snap" -type f | wc -l)"
[[ "$left" -eq 0 ]] || fail "a short read left $left files behind for the census to read"
grep -q "resumed" "$work/audit" || fail "the server was not resumed after a short read"
echo "  ok: a file shorter than its committed length is refused, not published"

echo "all census snapshotter cases passed"
