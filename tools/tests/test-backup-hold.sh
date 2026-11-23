#!/usr/bin/env bash
# Runs the backup job's own script against a fake server whose console is as
# busy as the real one.
#
# The script finds out which files to copy by sending `save query` and reading
# the server's reply off the console. That console is shared: the map's live
# layer writes several lines a second, and on 2026-10-06 the reply was no
# longer in the 20 lines the script read, so the hold was abandoned and the
# cold copy that followed failed. The fake honours --tail and --since as the
# real kubectl does, which is the property that failure depended on: the reply
# is FAKE_REPLY_AGE seconds old, the map's lines are newer, and a reader gets
# only what its window reaches.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/minecraft-fwb"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template jdwillmsen-minecraft-fwb-prd "$chart" -n jdwillmsen-prd \
  -f "$chart/values.yaml" -f "$chart/values-prd.yaml" \
  -f "$chart/values-console-bridge.yaml" > "$work/rendered.yaml"

# The script and its environment as the CronJob carries them.
python3 - "$work/rendered.yaml" "$work" <<'PY' || fail "could not extract the backup script from the chart"
import shlex, sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc.get("kind") == "CronJob" and doc["metadata"]["name"].endswith("-backup"):
        c = doc["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]
        open(sys.argv[2] + "/backup.sh", "w").write(c["args"][0])
        with open(sys.argv[2] + "/env", "w") as env:
            for e in c.get("env", []):
                if "value" in e:
                    env.write("export %s=%s\n" % (e["name"], shlex.quote(str(e["value"]))))
        break
else:
    sys.exit("no backup CronJob rendered")
PY

# Staged outside the container's own paths, so the suite needs no root and no
# volume.
mkdir -p "$work/sa" "$work/backup" "$work/bin"
echo -n "test-ns" > "$work/sa/namespace"
# The retention script comes from the chart's own file. Copied to a name with no
# "/backup" in its path, which the substitution below would otherwise mangle.
cp "$chart/scripts/backup-retention.py" "$work/bin/retention.py"
sed -i -e "s|/opt/retention/backup-retention.py|$work/bin/retention.py|g" \
       -e "s|/tmp/archive-metrics.txt|$work/archive-metrics.txt|g" \
       -e "s|/tmp/chunks-backfill.txt|$work/chunks-backfill.txt|g" \
       -e "s|/var/run/secrets/kubernetes.io/serviceaccount/namespace|$work/sa/namespace|" \
       -e "s|/data/worlds|$work/worlds|g" -e "s|/backup|$work/backup|g" \
       -e "s|/tmp/metrics.txt|$work/metrics.txt|g" "$work/backup.sh"

# shellcheck disable=SC1091  # written above from the rendered chart
. "$work/env"
level="${LEVEL_NAME:?the backup CronJob names no level}"
mkdir -p "$work/worlds/$level/db"
head -c 4096 /dev/urandom > "$work/worlds/$level/db/000001.ldb"
head -c 4096 /dev/urandom > "$work/worlds/$level/db/MANIFEST-000001"
head -c 2048 /dev/urandom > "$work/worlds/$level/level.dat"
# The server commits fewer bytes than the first file holds on disk, as it does
# for a file LevelDB is still appending to.
manifest="$level/db/000001.ldb:1000, $level/db/MANIFEST-000001:4096, $level/level.dat:2048"

cat > "$work/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  get)
    case "$*" in
      *--raw*)
        # The map's census, as the API server proxy would serve it.
        printf 'mcmap_world_chunks{dimension="overworld"} 1000\nmcmap_world_chunks{dimension="end"} 34\n'
        printf 'mcmap_world_chunks_lost{dimension="overworld"} 7\n'
        printf 'mcmap_world_census_last_success_timestamp_seconds %s\n' "$(date +%s)" ;;
      *statefulset*) printf 1 ;;
      *phase*)       printf "${FAKE_PHASE:-Running}" ;;
      *Ready*)       printf True ;;
    esac ;;
  exec)
    shift; while [[ "$1" != "--" ]]; do shift; done; shift 2
    printf '%s\n' "$*" >> "$CAPTURE" ;;
  logs)
    tail="" since=""
    for arg in "$@"; do
      [[ "$arg" == --tail=* ]] && tail="${arg#--tail=}"
      [[ "$arg" == --since=* ]] && since="${arg#--since=}"
    done
    since="${since%s}"
    # The script sleeps two seconds between asking and reading, and each call
    # takes time of its own, so the reply is some seconds old when it is read.
    age="${FAKE_REPLY_AGE:-5}"
    {
      if [[ -z "$since" || "$age" -le "$since" ]]; then
        printf 'noise \x00 binary\n'
        echo '[2026-10-06 04:00:09:480 INFO] Data saved. Files are now ready to be copied.'
        echo "$FAKE_MANIFEST"
      fi
      for _ in $(seq 1 "${FAKE_NOISE:-0}"); do
        echo '[2026-10-06 04:00:10:607 INFO] [Scripting] MCMAP1 {"gen":28230,"kind":"tick","players":3,"mobs":362}'
      done
    } > "$CAPTURE.console"
    if [[ -n "$tail" ]]; then tail -n "$tail" "$CAPTURE.console"; else cat "$CAPTURE.console"; fi ;;
esac
exit 0
SHIM
chmod +x "$work/bin/kubectl"

rc=0
run() {
  : > "$work/sent"; rm -rf "$work/backup"; mkdir -p "$work/backup"
  rc=0
  out="$(env PATH="$work/bin:$PATH" CAPTURE="$work/sent" FAKE_MANIFEST="$manifest" MIN_BYTES=1 \
    timeout 120 bash "$work/backup.sh" 2>&1)" || rc=$?
}

# --- the reply is found however much else the console says ------------------
FAKE_NOISE=100 run
grep -q 'copied 3 files under hold' <<<"$out" || fail "the manifest was not read off a busy console: $out"
grep -q 'falling back to a cold copy' <<<"$out" && fail "a server that answered was treated as one that did not: $out"
[ "$rc" -eq 0 ] || fail "a held backup exited $rc: $out"
archive="$(find "$work/backup" -name 'fwb-*.tar.gz' | head -1)"
[ -n "$archive" ] || fail "no archive was written: $out"
size="$(tar xzf "$archive" -O "./$level/db/000001.ldb" | wc -c)"
[ "$size" -eq 1000 ] || fail "the archive holds $size bytes of a file the server committed 1000 of"
grep -q '^save hold$' "$work/sent" || fail "the server was never asked to hold"
[ "$(tail -1 "$work/sent")" = "save resume" ] || fail "the server was left held: $(tr '\n' ';' < "$work/sent")"
echo "  ok: a held backup reads its manifest through a console the map is writing to"

# --- and on a quiet console, as before --------------------------------------
run
grep -q 'copied 3 files under hold' <<<"$out" || fail "the manifest was not read off a quiet console: $out"
[ "$rc" -eq 0 ] || fail "a held backup on a quiet console exited $rc: $out"
echo "  ok: a quiet console still works"

# --- the archive records what it holds, and only a quiesced one gets a count --
meta="$(find "$work/backup" -name 'fwb-*.tar.gz.meta' | head -1)"
grep -q '^chunks=1034$' "$meta" || fail "a held archive was not given the map's count: $(cat "$meta")"
grep -q '^lost=7$' "$meta" || fail "the loss ledger was not recorded: $(cat "$meta")"
grep -q '^ldb_files=1$' "$meta" || fail "the table-file count was not recorded: $(cat "$meta")"
grep -q '^backup_archive_chunks{' "$work/archive-metrics.txt" || fail "per-archive metrics were not written"
grep -q '^backup_archive_chunks{' "$work/metrics.txt" || fail "per-archive metrics did not reach the published payload"
echo "  ok: a held archive is recorded with the census count"

# A cold copy (the server is not Ready but is meant to be running) is not the
# world the map counted, so it is recorded without a count. The ledger is still
# the live world's and is kept.
FAKE_PHASE=Pending run
[ "$rc" -eq 0 ] || fail "a cold backup exited $rc: $out"
grep -q 'falling back to a cold copy' <<<"$out" || fail "the cold path was not taken: $out"
meta="$(find "$work/backup" -name 'fwb-*.tar.gz.meta' | head -1)"
grep -q '^quiesced=0$' "$meta" || fail "expected an unquiesced archive: $(cat "$meta")"
grep -q '^chunks=' "$meta" && fail "an unquiesced archive was given the map's count: $(cat "$meta")"
grep -q '^lost=7$' "$meta" || fail "the ledger was not recorded for a cold archive: $(cat "$meta")"
grep -q 'reason="chunks-unknown"} 1' "$work/archive-metrics.txt" || fail "retention did not hold on an uncounted archive"
echo "  ok: a cold copy is not given a count and retention holds"

# A census that cannot be read is logged with its error, not swallowed, and the
# backup still completes.
cat > "$work/bin/kubectl-denied" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1" == get && "$*" == *--raw* ]]; then echo 'Error from server (Forbidden): services/proxy denied' >&2; exit 1; fi
exec "$(dirname "$0")/kubectl" "$@"
SHIM
chmod +x "$work/bin/kubectl-denied"
mv "$work/bin/kubectl" "$work/bin/kubectl-real"; sed -i 's|/kubectl" "\$@"|/kubectl-real" "$@"|' "$work/bin/kubectl-denied"; mv "$work/bin/kubectl-denied" "$work/bin/kubectl"
run
[ "$rc" -eq 0 ] || fail "a backup with an unreadable census exited $rc: $out"
grep -q 'reading the map census failed: Error from server (Forbidden)' <<<"$out" || fail "the census error was swallowed: $out"
echo "  ok: an unreadable census is reported, not hidden"

echo "PASS"
